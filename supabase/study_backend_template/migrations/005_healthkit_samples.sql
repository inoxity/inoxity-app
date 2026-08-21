-- STUDY DATA BACKEND ONLY
-- Readable HealthKit samples. Never apply to inoxity_backend.
--
-- One dedicated table per HealthKit data type (mirrors the pre-dashboard
-- app's `sleep_samples` table) instead of one generic table with a
-- health_type_identifier discriminator column — easier for a researcher to
-- query/export a single data type without filtering. A study only needs the
-- tables for the types it actually configured; the dashboard's "Download
-- setup SQL" generates just those (see inoxity-dashboard/src/lib/
-- generate-backend-sql.ts). This file is the full reference version — every
-- supported type — for manual application per the README walkthrough.
--
-- Every table shares the same identity/ownership envelope (participant_id,
-- enrollment_id, stable_study_id, client_sample_id, sample_uuid,
-- sample_start/end, sample_time_zone, configuration_schema_version/revision,
-- received_at/created_at) plus type-specific value column(s). sample_time_zone
-- is the IANA identifier the sample actually occurred in (nullable — older
-- app builds won't send it); local wall-clock time can be reconstructed
-- later with sample_start AT TIME ZONE sample_time_zone rather than guessing
-- at analysis time, which matters since HealthKit data is routinely
-- backfilled from a device that may have since traveled.
--   - sleepAnalysis alone gets a friendly six-value `state` text column —
--     it predates everything else here and stays that way for readability.
--   - Every other category type (heart-rhythm events, mindfulness,
--     reproductive health, symptoms) instead gets a generic `category_value
--     integer` column, since each has its own different HealthKit enum and
--     hand-maintaining a text mapping per type doesn't scale at this size —
--     see HealthKitTypeRegistry.swift and generate-backend-sql.ts for what
--     each integer means for a given identifier.
--   - `bloodPressure` (a correlation, not a plain quantity) gets two numeric
--     columns, systolic and diastolic, both required together.
--   - Everything else is a single numeric or (workout) two-column row.
-- RLS is enabled and all direct access is revoked on every table — only the
-- `submit_healthkit_samples` RPC (006) writes to them.

create table if not exists public.sleep_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    state text not null check (state in ('inBed','asleepUnspecified','awake','asleepCore','asleepDeep','asleepREM')),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.step_count_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    steps double precision not null check (steps = steps and steps not in ('Infinity'::float8, '-Infinity'::float8) and steps >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.resting_heart_rate_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    bpm double precision not null check (bpm = bpm and bpm not in ('Infinity'::float8, '-Infinity'::float8) and bpm >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.heart_rate_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    bpm double precision not null check (bpm = bpm and bpm not in ('Infinity'::float8, '-Infinity'::float8) and bpm >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.heart_rate_variability_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    sdnn_ms double precision not null check (sdnn_ms = sdnn_ms and sdnn_ms not in ('Infinity'::float8, '-Infinity'::float8) and sdnn_ms >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.active_energy_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    kcal double precision not null check (kcal = kcal and kcal not in ('Infinity'::float8, '-Infinity'::float8) and kcal >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.exercise_time_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    minutes double precision not null check (minutes = minutes and minutes not in ('Infinity'::float8, '-Infinity'::float8) and minutes >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.respiratory_rate_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    breaths_per_min double precision not null check (breaths_per_min = breaths_per_min and breaths_per_min not in ('Infinity'::float8, '-Infinity'::float8) and breaths_per_min >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.daylight_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    minutes double precision not null check (minutes = minutes and minutes not in ('Infinity'::float8, '-Infinity'::float8) and minutes >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.workout_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    activity_type bigint not null,
    duration_seconds double precision not null check (duration_seconds = duration_seconds and duration_seconds not in ('Infinity'::float8, '-Infinity'::float8) and duration_seconds >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.distance_walking_running_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    miles double precision not null check (miles = miles and miles not in ('Infinity'::float8, '-Infinity'::float8) and miles >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.distance_cycling_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    miles double precision not null check (miles = miles and miles not in ('Infinity'::float8, '-Infinity'::float8) and miles >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.distance_swimming_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    miles double precision not null check (miles = miles and miles not in ('Infinity'::float8, '-Infinity'::float8) and miles >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.distance_wheelchair_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    miles double precision not null check (miles = miles and miles not in ('Infinity'::float8, '-Infinity'::float8) and miles >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.flights_climbed_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.push_count_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.swimming_stroke_count_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.basal_energy_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    kcal double precision not null check (kcal = kcal and kcal not in ('Infinity'::float8, '-Infinity'::float8) and kcal >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.stand_time_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    minutes double precision not null check (minutes = minutes and minutes not in ('Infinity'::float8, '-Infinity'::float8) and minutes >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.walking_speed_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters_per_second double precision not null check (meters_per_second = meters_per_second and meters_per_second not in ('Infinity'::float8, '-Infinity'::float8) and meters_per_second >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.walking_step_length_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters double precision not null check (meters = meters and meters not in ('Infinity'::float8, '-Infinity'::float8) and meters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.walking_asymmetry_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    percent double precision not null check (percent = percent and percent not in ('Infinity'::float8, '-Infinity'::float8) and percent >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.walking_double_support_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    percent double precision not null check (percent = percent and percent not in ('Infinity'::float8, '-Infinity'::float8) and percent >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.six_minute_walk_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters double precision not null check (meters = meters and meters not in ('Infinity'::float8, '-Infinity'::float8) and meters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.stair_ascent_speed_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters_per_second double precision not null check (meters_per_second = meters_per_second and meters_per_second not in ('Infinity'::float8, '-Infinity'::float8) and meters_per_second >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.stair_descent_speed_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters_per_second double precision not null check (meters_per_second = meters_per_second and meters_per_second not in ('Infinity'::float8, '-Infinity'::float8) and meters_per_second >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.height_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters double precision not null check (meters = meters and meters not in ('Infinity'::float8, '-Infinity'::float8) and meters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.body_mass_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    kg double precision not null check (kg = kg and kg not in ('Infinity'::float8, '-Infinity'::float8) and kg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.body_mass_index_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    value double precision not null check (value = value and value not in ('Infinity'::float8, '-Infinity'::float8) and value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.lean_body_mass_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    kg double precision not null check (kg = kg and kg not in ('Infinity'::float8, '-Infinity'::float8) and kg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.body_fat_percentage_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    percent double precision not null check (percent = percent and percent not in ('Infinity'::float8, '-Infinity'::float8) and percent >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.waist_circumference_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters double precision not null check (meters = meters and meters not in ('Infinity'::float8, '-Infinity'::float8) and meters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.body_temperature_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    celsius double precision not null check (celsius = celsius and celsius not in ('Infinity'::float8, '-Infinity'::float8) and celsius >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.basal_body_temperature_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    celsius double precision not null check (celsius = celsius and celsius not in ('Infinity'::float8, '-Infinity'::float8) and celsius >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.electrodermal_activity_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    microsiemens double precision not null check (microsiemens = microsiemens and microsiemens not in ('Infinity'::float8, '-Infinity'::float8) and microsiemens >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.oxygen_saturation_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    percent double precision not null check (percent = percent and percent not in ('Infinity'::float8, '-Infinity'::float8) and percent >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.blood_glucose_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg_per_dl double precision not null check (mg_per_dl = mg_per_dl and mg_per_dl not in ('Infinity'::float8, '-Infinity'::float8) and mg_per_dl >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.forced_vital_capacity_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    liters double precision not null check (liters = liters and liters not in ('Infinity'::float8, '-Infinity'::float8) and liters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.forced_expiratory_volume_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    liters double precision not null check (liters = liters and liters not in ('Infinity'::float8, '-Infinity'::float8) and liters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.peak_expiratory_flow_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    liters_per_min double precision not null check (liters_per_min = liters_per_min and liters_per_min not in ('Infinity'::float8, '-Infinity'::float8) and liters_per_min >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.inhaler_usage_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.insulin_delivery_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    iu double precision not null check (iu = iu and iu not in ('Infinity'::float8, '-Infinity'::float8) and iu >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.falls_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.environmental_audio_exposure_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    dbaspl double precision not null check (dbaspl = dbaspl and dbaspl not in ('Infinity'::float8, '-Infinity'::float8) and dbaspl >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.headphone_audio_exposure_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    dbaspl double precision not null check (dbaspl = dbaspl and dbaspl not in ('Infinity'::float8, '-Infinity'::float8) and dbaspl >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.uv_exposure_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    count double precision not null check (count = count and count not in ('Infinity'::float8, '-Infinity'::float8) and count >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.water_temperature_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    celsius double precision not null check (celsius = celsius and celsius not in ('Infinity'::float8, '-Infinity'::float8) and celsius >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.underwater_depth_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    meters double precision not null check (meters = meters and meters not in ('Infinity'::float8, '-Infinity'::float8) and meters >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_energy_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    kcal double precision not null check (kcal = kcal and kcal not in ('Infinity'::float8, '-Infinity'::float8) and kcal >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_protein_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_carbohydrates_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_fiber_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_sugar_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_fat_total_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_fat_saturated_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_fat_monounsaturated_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_fat_polyunsaturated_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    grams double precision not null check (grams = grams and grams not in ('Infinity'::float8, '-Infinity'::float8) and grams >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_cholesterol_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_sodium_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_potassium_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_calcium_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_iron_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_magnesium_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_zinc_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_a_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mcg double precision not null check (mcg = mcg and mcg not in ('Infinity'::float8, '-Infinity'::float8) and mcg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_c_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_d_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mcg double precision not null check (mcg = mcg and mcg not in ('Infinity'::float8, '-Infinity'::float8) and mcg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_e_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_k_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mcg double precision not null check (mcg = mcg and mcg not in ('Infinity'::float8, '-Infinity'::float8) and mcg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_b6_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_vitamin_b12_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mcg double precision not null check (mcg = mcg and mcg not in ('Infinity'::float8, '-Infinity'::float8) and mcg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_caffeine_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    mg double precision not null check (mg = mg and mg not in ('Infinity'::float8, '-Infinity'::float8) and mg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.dietary_water_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    ml double precision not null check (ml = ml and ml not in ('Infinity'::float8, '-Infinity'::float8) and ml >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.high_heart_rate_event_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.low_heart_rate_event_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.irregular_heart_rhythm_event_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.mindful_session_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.menstrual_flow_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.intermenstrual_bleeding_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.sexual_activity_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.ovulation_test_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.contraceptive_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.pregnancy_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.pregnancy_test_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.lactation_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.cervical_mucus_quality_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_abdominal_cramps_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_bloating_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_constipation_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_diarrhea_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_dizziness_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_fatigue_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_fever_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_body_ache_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_headache_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_heartburn_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_loss_of_smell_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_loss_of_taste_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_nausea_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_rapid_heartbeat_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_runny_nose_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_shortness_of_breath_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_sinus_congestion_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_sore_throat_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_vomiting_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_wheezing_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_coughing_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_chills_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_chest_tightness_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_mood_changes_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_sleep_changes_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_memory_lapse_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_hot_flashes_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_lower_back_pain_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_appetite_changes_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.symptom_bladder_incontinence_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    category_value integer not null check (category_value >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

create table if not exists public.blood_pressure_samples (
    id uuid primary key default gen_random_uuid(),
    client_sample_id text not null unique check (char_length(client_sample_id) between 20 and 250),
    participant_id uuid not null references public.participants(id) on delete cascade,
    enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
    stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
    sample_uuid uuid not null,
    sample_start timestamptz not null,
    sample_end timestamptz not null check (sample_end >= sample_start),
    sample_time_zone text,
    systolic_mmhg double precision not null check (systolic_mmhg = systolic_mmhg and systolic_mmhg not in ('Infinity'::float8, '-Infinity'::float8) and systolic_mmhg >= 0),
    diastolic_mmhg double precision not null check (diastolic_mmhg = diastolic_mmhg and diastolic_mmhg not in ('Infinity'::float8, '-Infinity'::float8) and diastolic_mmhg >= 0),
    configuration_schema_version integer not null check (configuration_schema_version > 0),
    configuration_revision integer not null check (configuration_revision > 0),
    received_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    unique (enrollment_id, sample_uuid)
);

alter table public.sleep_samples enable row level security;
alter table public.step_count_samples enable row level security;
alter table public.resting_heart_rate_samples enable row level security;
alter table public.heart_rate_samples enable row level security;
alter table public.heart_rate_variability_samples enable row level security;
alter table public.active_energy_samples enable row level security;
alter table public.exercise_time_samples enable row level security;
alter table public.respiratory_rate_samples enable row level security;
alter table public.daylight_samples enable row level security;
alter table public.workout_samples enable row level security;
alter table public.distance_walking_running_samples enable row level security;
alter table public.distance_cycling_samples enable row level security;
alter table public.distance_swimming_samples enable row level security;
alter table public.distance_wheelchair_samples enable row level security;
alter table public.flights_climbed_samples enable row level security;
alter table public.push_count_samples enable row level security;
alter table public.swimming_stroke_count_samples enable row level security;
alter table public.basal_energy_samples enable row level security;
alter table public.stand_time_samples enable row level security;
alter table public.walking_speed_samples enable row level security;
alter table public.walking_step_length_samples enable row level security;
alter table public.walking_asymmetry_samples enable row level security;
alter table public.walking_double_support_samples enable row level security;
alter table public.six_minute_walk_samples enable row level security;
alter table public.stair_ascent_speed_samples enable row level security;
alter table public.stair_descent_speed_samples enable row level security;
alter table public.height_samples enable row level security;
alter table public.body_mass_samples enable row level security;
alter table public.body_mass_index_samples enable row level security;
alter table public.lean_body_mass_samples enable row level security;
alter table public.body_fat_percentage_samples enable row level security;
alter table public.waist_circumference_samples enable row level security;
alter table public.body_temperature_samples enable row level security;
alter table public.basal_body_temperature_samples enable row level security;
alter table public.electrodermal_activity_samples enable row level security;
alter table public.oxygen_saturation_samples enable row level security;
alter table public.blood_glucose_samples enable row level security;
alter table public.forced_vital_capacity_samples enable row level security;
alter table public.forced_expiratory_volume_samples enable row level security;
alter table public.peak_expiratory_flow_samples enable row level security;
alter table public.inhaler_usage_samples enable row level security;
alter table public.insulin_delivery_samples enable row level security;
alter table public.falls_samples enable row level security;
alter table public.environmental_audio_exposure_samples enable row level security;
alter table public.headphone_audio_exposure_samples enable row level security;
alter table public.uv_exposure_samples enable row level security;
alter table public.water_temperature_samples enable row level security;
alter table public.underwater_depth_samples enable row level security;
alter table public.dietary_energy_samples enable row level security;
alter table public.dietary_protein_samples enable row level security;
alter table public.dietary_carbohydrates_samples enable row level security;
alter table public.dietary_fiber_samples enable row level security;
alter table public.dietary_sugar_samples enable row level security;
alter table public.dietary_fat_total_samples enable row level security;
alter table public.dietary_fat_saturated_samples enable row level security;
alter table public.dietary_fat_monounsaturated_samples enable row level security;
alter table public.dietary_fat_polyunsaturated_samples enable row level security;
alter table public.dietary_cholesterol_samples enable row level security;
alter table public.dietary_sodium_samples enable row level security;
alter table public.dietary_potassium_samples enable row level security;
alter table public.dietary_calcium_samples enable row level security;
alter table public.dietary_iron_samples enable row level security;
alter table public.dietary_magnesium_samples enable row level security;
alter table public.dietary_zinc_samples enable row level security;
alter table public.dietary_vitamin_a_samples enable row level security;
alter table public.dietary_vitamin_c_samples enable row level security;
alter table public.dietary_vitamin_d_samples enable row level security;
alter table public.dietary_vitamin_e_samples enable row level security;
alter table public.dietary_vitamin_k_samples enable row level security;
alter table public.dietary_vitamin_b6_samples enable row level security;
alter table public.dietary_vitamin_b12_samples enable row level security;
alter table public.dietary_caffeine_samples enable row level security;
alter table public.dietary_water_samples enable row level security;
alter table public.high_heart_rate_event_samples enable row level security;
alter table public.low_heart_rate_event_samples enable row level security;
alter table public.irregular_heart_rhythm_event_samples enable row level security;
alter table public.mindful_session_samples enable row level security;
alter table public.menstrual_flow_samples enable row level security;
alter table public.intermenstrual_bleeding_samples enable row level security;
alter table public.sexual_activity_samples enable row level security;
alter table public.ovulation_test_samples enable row level security;
alter table public.contraceptive_samples enable row level security;
alter table public.pregnancy_samples enable row level security;
alter table public.pregnancy_test_samples enable row level security;
alter table public.lactation_samples enable row level security;
alter table public.cervical_mucus_quality_samples enable row level security;
alter table public.symptom_abdominal_cramps_samples enable row level security;
alter table public.symptom_bloating_samples enable row level security;
alter table public.symptom_constipation_samples enable row level security;
alter table public.symptom_diarrhea_samples enable row level security;
alter table public.symptom_dizziness_samples enable row level security;
alter table public.symptom_fatigue_samples enable row level security;
alter table public.symptom_fever_samples enable row level security;
alter table public.symptom_body_ache_samples enable row level security;
alter table public.symptom_headache_samples enable row level security;
alter table public.symptom_heartburn_samples enable row level security;
alter table public.symptom_loss_of_smell_samples enable row level security;
alter table public.symptom_loss_of_taste_samples enable row level security;
alter table public.symptom_nausea_samples enable row level security;
alter table public.symptom_rapid_heartbeat_samples enable row level security;
alter table public.symptom_runny_nose_samples enable row level security;
alter table public.symptom_shortness_of_breath_samples enable row level security;
alter table public.symptom_sinus_congestion_samples enable row level security;
alter table public.symptom_sore_throat_samples enable row level security;
alter table public.symptom_vomiting_samples enable row level security;
alter table public.symptom_wheezing_samples enable row level security;
alter table public.symptom_coughing_samples enable row level security;
alter table public.symptom_chills_samples enable row level security;
alter table public.symptom_chest_tightness_samples enable row level security;
alter table public.symptom_mood_changes_samples enable row level security;
alter table public.symptom_sleep_changes_samples enable row level security;
alter table public.symptom_memory_lapse_samples enable row level security;
alter table public.symptom_hot_flashes_samples enable row level security;
alter table public.symptom_lower_back_pain_samples enable row level security;
alter table public.symptom_appetite_changes_samples enable row level security;
alter table public.symptom_bladder_incontinence_samples enable row level security;
alter table public.blood_pressure_samples enable row level security;
revoke all on public.sleep_samples, public.step_count_samples, public.resting_heart_rate_samples,
  public.heart_rate_samples, public.heart_rate_variability_samples, public.active_energy_samples,
  public.exercise_time_samples, public.respiratory_rate_samples, public.daylight_samples,
  public.workout_samples, public.distance_walking_running_samples,
  public.distance_cycling_samples, public.distance_swimming_samples,
  public.distance_wheelchair_samples, public.flights_climbed_samples, public.push_count_samples,
  public.swimming_stroke_count_samples, public.basal_energy_samples, public.stand_time_samples,
  public.walking_speed_samples, public.walking_step_length_samples,
  public.walking_asymmetry_samples, public.walking_double_support_samples,
  public.six_minute_walk_samples, public.stair_ascent_speed_samples,
  public.stair_descent_speed_samples, public.height_samples, public.body_mass_samples,
  public.body_mass_index_samples, public.lean_body_mass_samples,
  public.body_fat_percentage_samples, public.waist_circumference_samples,
  public.body_temperature_samples, public.basal_body_temperature_samples,
  public.electrodermal_activity_samples, public.oxygen_saturation_samples,
  public.blood_glucose_samples, public.forced_vital_capacity_samples,
  public.forced_expiratory_volume_samples, public.peak_expiratory_flow_samples,
  public.inhaler_usage_samples, public.insulin_delivery_samples, public.falls_samples,
  public.environmental_audio_exposure_samples, public.headphone_audio_exposure_samples,
  public.uv_exposure_samples, public.water_temperature_samples, public.underwater_depth_samples,
  public.dietary_energy_samples, public.dietary_protein_samples,
  public.dietary_carbohydrates_samples, public.dietary_fiber_samples,
  public.dietary_sugar_samples, public.dietary_fat_total_samples,
  public.dietary_fat_saturated_samples, public.dietary_fat_monounsaturated_samples,
  public.dietary_fat_polyunsaturated_samples, public.dietary_cholesterol_samples,
  public.dietary_sodium_samples, public.dietary_potassium_samples, public.dietary_calcium_samples,
  public.dietary_iron_samples, public.dietary_magnesium_samples, public.dietary_zinc_samples,
  public.dietary_vitamin_a_samples, public.dietary_vitamin_c_samples,
  public.dietary_vitamin_d_samples, public.dietary_vitamin_e_samples,
  public.dietary_vitamin_k_samples, public.dietary_vitamin_b6_samples,
  public.dietary_vitamin_b12_samples, public.dietary_caffeine_samples,
  public.dietary_water_samples, public.high_heart_rate_event_samples,
  public.low_heart_rate_event_samples, public.irregular_heart_rhythm_event_samples,
  public.mindful_session_samples, public.menstrual_flow_samples,
  public.intermenstrual_bleeding_samples, public.sexual_activity_samples,
  public.ovulation_test_samples, public.contraceptive_samples, public.pregnancy_samples,
  public.pregnancy_test_samples, public.lactation_samples, public.cervical_mucus_quality_samples,
  public.symptom_abdominal_cramps_samples, public.symptom_bloating_samples,
  public.symptom_constipation_samples, public.symptom_diarrhea_samples,
  public.symptom_dizziness_samples, public.symptom_fatigue_samples, public.symptom_fever_samples,
  public.symptom_body_ache_samples, public.symptom_headache_samples,
  public.symptom_heartburn_samples, public.symptom_loss_of_smell_samples,
  public.symptom_loss_of_taste_samples, public.symptom_nausea_samples,
  public.symptom_rapid_heartbeat_samples, public.symptom_runny_nose_samples,
  public.symptom_shortness_of_breath_samples, public.symptom_sinus_congestion_samples,
  public.symptom_sore_throat_samples, public.symptom_vomiting_samples,
  public.symptom_wheezing_samples, public.symptom_coughing_samples, public.symptom_chills_samples,
  public.symptom_chest_tightness_samples, public.symptom_mood_changes_samples,
  public.symptom_sleep_changes_samples, public.symptom_memory_lapse_samples,
  public.symptom_hot_flashes_samples, public.symptom_lower_back_pain_samples,
  public.symptom_appetite_changes_samples, public.symptom_bladder_incontinence_samples,
  public.blood_pressure_samples
from anon, authenticated;

comment on table public.sleep_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for sleepAnalysis.';
comment on table public.step_count_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for stepCount.';
comment on table public.resting_heart_rate_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for restingHeartRate.';
comment on table public.heart_rate_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for heartRate.';
comment on table public.heart_rate_variability_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for heartRateVariabilitySDNN.';
comment on table public.active_energy_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for activeEnergyBurned.';
comment on table public.exercise_time_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for appleExerciseTime.';
comment on table public.respiratory_rate_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for respiratoryRate.';
comment on table public.daylight_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for timeInDaylight.';
comment on table public.workout_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for workout.';
comment on table public.distance_walking_running_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for distanceWalkingRunning.';
comment on table public.distance_cycling_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for distanceCycling.';
comment on table public.distance_swimming_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for distanceSwimming.';
comment on table public.distance_wheelchair_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for distanceWheelchair.';
comment on table public.flights_climbed_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for flightsClimbed.';
comment on table public.push_count_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for pushCount.';
comment on table public.swimming_stroke_count_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for swimmingStrokeCount.';
comment on table public.basal_energy_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for basalEnergyBurned.';
comment on table public.stand_time_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for appleStandTime.';
comment on table public.walking_speed_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for walkingSpeed.';
comment on table public.walking_step_length_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for walkingStepLength.';
comment on table public.walking_asymmetry_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for walkingAsymmetryPercentage.';
comment on table public.walking_double_support_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for walkingDoubleSupportPercentage.';
comment on table public.six_minute_walk_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for sixMinuteWalkTestDistance.';
comment on table public.stair_ascent_speed_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for stairAscentSpeed.';
comment on table public.stair_descent_speed_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for stairDescentSpeed.';
comment on table public.height_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for height.';
comment on table public.body_mass_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bodyMass.';
comment on table public.body_mass_index_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bodyMassIndex.';
comment on table public.lean_body_mass_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for leanBodyMass.';
comment on table public.body_fat_percentage_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bodyFatPercentage.';
comment on table public.waist_circumference_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for waistCircumference.';
comment on table public.body_temperature_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bodyTemperature.';
comment on table public.basal_body_temperature_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for basalBodyTemperature.';
comment on table public.electrodermal_activity_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for electrodermalActivity.';
comment on table public.oxygen_saturation_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for oxygenSaturation.';
comment on table public.blood_glucose_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bloodGlucose.';
comment on table public.forced_vital_capacity_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for forcedVitalCapacity.';
comment on table public.forced_expiratory_volume_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for forcedExpiratoryVolume1.';
comment on table public.peak_expiratory_flow_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for peakExpiratoryFlowRate.';
comment on table public.inhaler_usage_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for inhalerUsage.';
comment on table public.insulin_delivery_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for insulinDelivery.';
comment on table public.falls_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for numberOfTimesFallen.';
comment on table public.environmental_audio_exposure_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for environmentalAudioExposure.';
comment on table public.headphone_audio_exposure_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for headphoneAudioExposure.';
comment on table public.uv_exposure_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for uvExposure.';
comment on table public.water_temperature_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for waterTemperature.';
comment on table public.underwater_depth_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for underwaterDepth.';
comment on table public.dietary_energy_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryEnergyConsumed.';
comment on table public.dietary_protein_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryProtein.';
comment on table public.dietary_carbohydrates_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryCarbohydrates.';
comment on table public.dietary_fiber_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryFiber.';
comment on table public.dietary_sugar_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietarySugar.';
comment on table public.dietary_fat_total_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryFatTotal.';
comment on table public.dietary_fat_saturated_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryFatSaturated.';
comment on table public.dietary_fat_monounsaturated_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryFatMonounsaturated.';
comment on table public.dietary_fat_polyunsaturated_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryFatPolyunsaturated.';
comment on table public.dietary_cholesterol_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryCholesterol.';
comment on table public.dietary_sodium_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietarySodium.';
comment on table public.dietary_potassium_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryPotassium.';
comment on table public.dietary_calcium_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryCalcium.';
comment on table public.dietary_iron_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryIron.';
comment on table public.dietary_magnesium_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryMagnesium.';
comment on table public.dietary_zinc_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryZinc.';
comment on table public.dietary_vitamin_a_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminA.';
comment on table public.dietary_vitamin_c_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminC.';
comment on table public.dietary_vitamin_d_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminD.';
comment on table public.dietary_vitamin_e_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminE.';
comment on table public.dietary_vitamin_k_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminK.';
comment on table public.dietary_vitamin_b6_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminB6.';
comment on table public.dietary_vitamin_b12_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryVitaminB12.';
comment on table public.dietary_caffeine_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryCaffeine.';
comment on table public.dietary_water_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dietaryWater.';
comment on table public.high_heart_rate_event_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for highHeartRateEvent.';
comment on table public.low_heart_rate_event_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for lowHeartRateEvent.';
comment on table public.irregular_heart_rhythm_event_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for irregularHeartRhythmEvent.';
comment on table public.mindful_session_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for mindfulSession.';
comment on table public.menstrual_flow_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for menstrualFlow.';
comment on table public.intermenstrual_bleeding_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for intermenstrualBleeding.';
comment on table public.sexual_activity_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for sexualActivity.';
comment on table public.ovulation_test_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for ovulationTestResult.';
comment on table public.contraceptive_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for contraceptive.';
comment on table public.pregnancy_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for pregnancy.';
comment on table public.pregnancy_test_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for pregnancyTestResult.';
comment on table public.lactation_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for lactation.';
comment on table public.cervical_mucus_quality_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for cervicalMucusQuality.';
comment on table public.symptom_abdominal_cramps_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for abdominalCramps.';
comment on table public.symptom_bloating_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bloating.';
comment on table public.symptom_constipation_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for constipation.';
comment on table public.symptom_diarrhea_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for diarrhea.';
comment on table public.symptom_dizziness_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for dizziness.';
comment on table public.symptom_fatigue_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for fatigue.';
comment on table public.symptom_fever_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for fever.';
comment on table public.symptom_body_ache_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for generalizedBodyAche.';
comment on table public.symptom_headache_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for headache.';
comment on table public.symptom_heartburn_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for heartburn.';
comment on table public.symptom_loss_of_smell_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for lossOfSmell.';
comment on table public.symptom_loss_of_taste_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for lossOfTaste.';
comment on table public.symptom_nausea_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for nausea.';
comment on table public.symptom_rapid_heartbeat_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for rapidPoundingOrFlutteringHeartbeat.';
comment on table public.symptom_runny_nose_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for runnyNose.';
comment on table public.symptom_shortness_of_breath_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for shortnessOfBreath.';
comment on table public.symptom_sinus_congestion_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for sinusCongestion.';
comment on table public.symptom_sore_throat_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for soreThroat.';
comment on table public.symptom_vomiting_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for vomiting.';
comment on table public.symptom_wheezing_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for wheezing.';
comment on table public.symptom_coughing_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for coughing.';
comment on table public.symptom_chills_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for chills.';
comment on table public.symptom_chest_tightness_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for chestTightnessOrPain.';
comment on table public.symptom_mood_changes_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for moodChanges.';
comment on table public.symptom_sleep_changes_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for sleepChanges.';
comment on table public.symptom_memory_lapse_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for memoryLapse.';
comment on table public.symptom_hot_flashes_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for hotFlashes.';
comment on table public.symptom_lower_back_pain_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for lowerBackPain.';
comment on table public.symptom_appetite_changes_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for appetiteChanges.';
comment on table public.symptom_bladder_incontinence_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bladderIncontinence.';
comment on table public.blood_pressure_samples is 'STUDY DATA BACKEND ONLY. Readable HealthKit samples for bloodPressure.';

