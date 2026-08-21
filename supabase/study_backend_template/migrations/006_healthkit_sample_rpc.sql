-- STUDY DATA BACKEND ONLY
-- Idempotent, ownership-checked HealthKit batch submission.
--
-- Same name/parameters/return shape regardless of which types a study uses
-- (the Swift app's `submitHealthKitSamples` in SupabaseRepositories.swift
-- calls this unchanged) — a batch can still mix multiple HealthKit types in
-- one call. Each sample is routed to its own per-type table (005) based on
-- `health_type_identifier`. `v_existing`/`v_row` are untyped `record`
-- variables (not `%rowtype`) specifically because they're reused across
-- branches pointing at different tables.
--
-- Four validation shapes appear below, matching 005's column shapes:
--   - sleepAnalysis: the original six-value `state` text branch.
--   - other category types: generic `category_value` integer branch.
--   - quantity types: single `numeric_value` branch.
--   - workout: `workout_activity_type` + `workout_duration_seconds` branch.
--   - bloodPressure (a correlation): `numeric_value` (systolic) +
--     `secondary_numeric_value` (diastolic) branch, both required together.
--
-- Every branch also writes `sample_time_zone` from `v_sample->>'sample_time_zone'` (nullable —
-- older app builds won't send it) alongside the envelope's sample_start/sample_end. It's
-- deliberately NOT part of the conflicting-duplicate-identity check each branch runs below —
-- contextual metadata, not part of a sample's identity the way sample_start/numeric_value are.

create or replace function public.submit_healthkit_samples(
  expected_backend_id uuid, expected_stable_study_id text, enrollment_id uuid, samples jsonb
) returns table(client_sample_id text, acknowledgment_id uuid, received_at timestamptz, idempotent_existing boolean)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_participant uuid; v_identity public.study_backend_metadata%rowtype; v_sample jsonb;
  v_identifier text; v_existing record; v_row record; v_state text;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if jsonb_typeof(samples) <> 'array' or jsonb_array_length(samples) < 1 or jsonb_array_length(samples) > 250 then
    raise exception 'invalid batch size' using errcode = '22023';
  end if;
  select * into v_identity from public.study_backend_metadata limit 1;
  if not found or not v_identity.is_active then
    raise exception 'study_backend_inactive' using errcode = '55000';
  end if;
  if v_identity.backend_instance_id <> expected_backend_id or v_identity.stable_study_id <> expected_stable_study_id then
    raise exception 'backend identity mismatch' using errcode = '42501';
  end if;
  select e.participant_id into v_participant from public.study_enrollments e join public.participants p on p.id=e.participant_id
    where e.id=enrollment_id and p.auth_user_id=auth.uid() and e.status='active';
  if v_participant is null then raise exception 'enrollment ownership denied' using errcode = '42501'; end if;

  for v_sample in select value from jsonb_array_elements(samples) loop
    v_identifier := v_sample->>'health_type_identifier';
    v_existing := null; v_row := null;

    if v_identifier = 'sleepAnalysis' then
      v_state := case (v_sample->>'category_value')::integer
        when 0 then 'inBed' when 1 then 'asleepUnspecified' when 2 then 'awake'
        when 3 then 'asleepCore' when 4 then 'asleepDeep' when 5 then 'asleepREM' else null end;
      if v_sample->>'sample_kind' <> 'category' or v_state is null then raise exception 'invalid sleep sample' using errcode='22023'; end if;
      select * into v_existing from public.sleep_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.state <> v_state
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.sleep_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,state,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',v_state,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'stepCount' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.step_count_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.steps <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.step_count_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,steps,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'restingHeartRate' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.resting_heart_rate_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.bpm <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.resting_heart_rate_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,bpm,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'heartRate' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.heart_rate_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.bpm <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.heart_rate_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,bpm,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'heartRateVariabilitySDNN' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.heart_rate_variability_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.sdnn_ms <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.heart_rate_variability_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,sdnn_ms,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'activeEnergyBurned' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.active_energy_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.kcal <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.active_energy_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,kcal,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'appleExerciseTime' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.exercise_time_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.minutes <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.exercise_time_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,minutes,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'respiratoryRate' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.respiratory_rate_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.breaths_per_min <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.respiratory_rate_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,breaths_per_min,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'timeInDaylight' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.daylight_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.minutes <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.daylight_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,minutes,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'workout' then
      if v_sample->>'sample_kind' <> 'workout' or v_sample->>'workout_activity_type' is null or v_sample->>'workout_duration_seconds' is null then raise exception 'invalid workout sample' using errcode='22023'; end if;
      select * into v_existing from public.workout_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.activity_type <> (v_sample->>'workout_activity_type')::bigint
           or v_existing.duration_seconds <> (v_sample->>'workout_duration_seconds')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.workout_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,activity_type,duration_seconds,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'workout_activity_type')::bigint,(v_sample->>'workout_duration_seconds')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'distanceWalkingRunning' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.distance_walking_running_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.miles <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.distance_walking_running_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,miles,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'distanceCycling' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.distance_cycling_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.miles <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.distance_cycling_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,miles,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'distanceSwimming' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.distance_swimming_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.miles <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.distance_swimming_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,miles,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'distanceWheelchair' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.distance_wheelchair_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.miles <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.distance_wheelchair_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,miles,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'flightsClimbed' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.flights_climbed_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.flights_climbed_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'pushCount' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.push_count_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.push_count_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'swimmingStrokeCount' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.swimming_stroke_count_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.swimming_stroke_count_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'basalEnergyBurned' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.basal_energy_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.kcal <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.basal_energy_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,kcal,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'appleStandTime' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.stand_time_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.minutes <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.stand_time_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,minutes,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'walkingSpeed' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.walking_speed_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters_per_second <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.walking_speed_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters_per_second,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'walkingStepLength' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.walking_step_length_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.walking_step_length_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'walkingAsymmetryPercentage' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.walking_asymmetry_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.percent <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.walking_asymmetry_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,percent,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'walkingDoubleSupportPercentage' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.walking_double_support_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.percent <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.walking_double_support_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,percent,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'sixMinuteWalkTestDistance' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.six_minute_walk_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.six_minute_walk_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'stairAscentSpeed' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.stair_ascent_speed_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters_per_second <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.stair_ascent_speed_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters_per_second,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'stairDescentSpeed' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.stair_descent_speed_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters_per_second <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.stair_descent_speed_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters_per_second,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'height' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.height_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.height_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bodyMass' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.body_mass_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.kg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.body_mass_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,kg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bodyMassIndex' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.body_mass_index_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.value <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.body_mass_index_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'leanBodyMass' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.lean_body_mass_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.kg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.lean_body_mass_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,kg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bodyFatPercentage' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.body_fat_percentage_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.percent <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.body_fat_percentage_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,percent,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'waistCircumference' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.waist_circumference_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.waist_circumference_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bodyTemperature' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.body_temperature_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.celsius <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.body_temperature_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,celsius,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'basalBodyTemperature' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.basal_body_temperature_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.celsius <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.basal_body_temperature_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,celsius,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'electrodermalActivity' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.electrodermal_activity_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.microsiemens <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.electrodermal_activity_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,microsiemens,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'oxygenSaturation' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.oxygen_saturation_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.percent <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.oxygen_saturation_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,percent,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bloodGlucose' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.blood_glucose_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg_per_dl <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.blood_glucose_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg_per_dl,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'forcedVitalCapacity' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.forced_vital_capacity_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.liters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.forced_vital_capacity_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,liters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'forcedExpiratoryVolume1' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.forced_expiratory_volume_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.liters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.forced_expiratory_volume_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,liters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'peakExpiratoryFlowRate' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.peak_expiratory_flow_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.liters_per_min <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.peak_expiratory_flow_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,liters_per_min,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'inhalerUsage' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.inhaler_usage_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.inhaler_usage_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'insulinDelivery' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.insulin_delivery_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.iu <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.insulin_delivery_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,iu,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'numberOfTimesFallen' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.falls_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.falls_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'environmentalAudioExposure' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.environmental_audio_exposure_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.dbaspl <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.environmental_audio_exposure_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,dbaspl,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'headphoneAudioExposure' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.headphone_audio_exposure_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.dbaspl <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.headphone_audio_exposure_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,dbaspl,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'uvExposure' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.uv_exposure_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.count <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.uv_exposure_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,count,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'waterTemperature' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.water_temperature_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.celsius <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.water_temperature_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,celsius,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'underwaterDepth' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.underwater_depth_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.meters <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.underwater_depth_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,meters,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryEnergyConsumed' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_energy_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.kcal <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_energy_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,kcal,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryProtein' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_protein_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_protein_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryCarbohydrates' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_carbohydrates_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_carbohydrates_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryFiber' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_fiber_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_fiber_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietarySugar' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_sugar_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_sugar_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryFatTotal' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_fat_total_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_fat_total_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryFatSaturated' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_fat_saturated_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_fat_saturated_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryFatMonounsaturated' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_fat_monounsaturated_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_fat_monounsaturated_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryFatPolyunsaturated' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_fat_polyunsaturated_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.grams <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_fat_polyunsaturated_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,grams,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryCholesterol' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_cholesterol_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_cholesterol_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietarySodium' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_sodium_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_sodium_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryPotassium' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_potassium_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_potassium_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryCalcium' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_calcium_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_calcium_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryIron' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_iron_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_iron_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryMagnesium' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_magnesium_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_magnesium_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryZinc' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_zinc_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_zinc_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminA' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_a_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mcg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_a_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mcg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminC' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_c_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_c_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminD' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_d_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mcg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_d_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mcg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminE' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_e_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_e_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminK' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_k_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mcg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_k_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mcg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminB6' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_b6_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_b6_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryVitaminB12' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_vitamin_b12_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mcg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_vitamin_b12_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mcg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryCaffeine' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_caffeine_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.mg <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_caffeine_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,mg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dietaryWater' then
      if v_sample->>'sample_kind' <> 'quantity' or v_sample->>'numeric_value' is null then raise exception 'invalid quantity sample' using errcode='22023'; end if;
      select * into v_existing from public.dietary_water_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.ml <> (v_sample->>'numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.dietary_water_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,ml,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'highHeartRateEvent' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.high_heart_rate_event_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.high_heart_rate_event_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'lowHeartRateEvent' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.low_heart_rate_event_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.low_heart_rate_event_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'irregularHeartRhythmEvent' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.irregular_heart_rhythm_event_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.irregular_heart_rhythm_event_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'mindfulSession' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.mindful_session_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.mindful_session_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'menstrualFlow' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.menstrual_flow_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.menstrual_flow_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'intermenstrualBleeding' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.intermenstrual_bleeding_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.intermenstrual_bleeding_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'sexualActivity' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.sexual_activity_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.sexual_activity_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'ovulationTestResult' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.ovulation_test_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.ovulation_test_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'contraceptive' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.contraceptive_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.contraceptive_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'pregnancy' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.pregnancy_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.pregnancy_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'pregnancyTestResult' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.pregnancy_test_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.pregnancy_test_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'lactation' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.lactation_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.lactation_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'cervicalMucusQuality' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.cervical_mucus_quality_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.cervical_mucus_quality_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'abdominalCramps' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_abdominal_cramps_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_abdominal_cramps_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bloating' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_bloating_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_bloating_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'constipation' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_constipation_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_constipation_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'diarrhea' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_diarrhea_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_diarrhea_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'dizziness' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_dizziness_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_dizziness_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'fatigue' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_fatigue_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_fatigue_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'fever' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_fever_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_fever_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'generalizedBodyAche' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_body_ache_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_body_ache_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'headache' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_headache_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_headache_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'heartburn' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_heartburn_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_heartburn_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'lossOfSmell' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_loss_of_smell_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_loss_of_smell_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'lossOfTaste' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_loss_of_taste_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_loss_of_taste_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'nausea' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_nausea_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_nausea_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'rapidPoundingOrFlutteringHeartbeat' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_rapid_heartbeat_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_rapid_heartbeat_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'runnyNose' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_runny_nose_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_runny_nose_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'shortnessOfBreath' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_shortness_of_breath_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_shortness_of_breath_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'sinusCongestion' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_sinus_congestion_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_sinus_congestion_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'soreThroat' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_sore_throat_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_sore_throat_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'vomiting' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_vomiting_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_vomiting_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'wheezing' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_wheezing_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_wheezing_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'coughing' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_coughing_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_coughing_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'chills' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_chills_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_chills_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'chestTightnessOrPain' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_chest_tightness_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_chest_tightness_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'moodChanges' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_mood_changes_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_mood_changes_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'sleepChanges' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_sleep_changes_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_sleep_changes_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'memoryLapse' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_memory_lapse_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_memory_lapse_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'hotFlashes' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_hot_flashes_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_hot_flashes_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'lowerBackPain' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_lower_back_pain_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_lower_back_pain_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'appetiteChanges' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_appetite_changes_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_appetite_changes_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bladderIncontinence' then
      if v_sample->>'sample_kind' <> 'category' or v_sample->>'category_value' is null then raise exception 'invalid category sample' using errcode='22023'; end if;
      select * into v_existing from public.symptom_bladder_incontinence_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.category_value <> (v_sample->>'category_value')::integer
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.symptom_bladder_incontinence_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,category_value,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'category_value')::integer,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    elsif v_identifier = 'bloodPressure' then
      if v_sample->>'sample_kind' <> 'correlation' or v_sample->>'numeric_value' is null or v_sample->>'secondary_numeric_value' is null then raise exception 'invalid correlation sample' using errcode='22023'; end if;
      select * into v_existing from public.blood_pressure_samples t where t.client_sample_id = v_sample->>'client_sample_id';
      if found then
        if v_existing.participant_id <> v_participant or v_existing.enrollment_id <> enrollment_id
           or v_existing.stable_study_id <> expected_stable_study_id
           or v_existing.sample_uuid <> (v_sample->>'sample_uuid')::uuid
           or v_existing.sample_start <> (v_sample->>'sample_start')::timestamptz
           or v_existing.sample_end <> (v_sample->>'sample_end')::timestamptz
           or v_existing.systolic_mmhg <> (v_sample->>'numeric_value')::double precision
           or v_existing.diastolic_mmhg <> (v_sample->>'secondary_numeric_value')::double precision
           or v_existing.configuration_schema_version <> (v_sample->>'configuration_schema_version')::integer
           or v_existing.configuration_revision <> (v_sample->>'configuration_revision')::integer
        then raise exception 'conflicting duplicate identity' using errcode='23505'; end if;
        client_sample_id:=v_existing.client_sample_id; acknowledgment_id:=v_existing.id; received_at:=v_existing.received_at; idempotent_existing:=true; return next; continue;
      end if;
      insert into public.blood_pressure_samples(client_sample_id,participant_id,enrollment_id,stable_study_id,sample_uuid,sample_start,sample_end,sample_time_zone,systolic_mmhg,diastolic_mmhg,configuration_schema_version,configuration_revision)
      values(v_sample->>'client_sample_id',v_participant,enrollment_id,expected_stable_study_id,(v_sample->>'sample_uuid')::uuid,(v_sample->>'sample_start')::timestamptz,(v_sample->>'sample_end')::timestamptz,v_sample->>'sample_time_zone',(v_sample->>'numeric_value')::double precision,(v_sample->>'secondary_numeric_value')::double precision,(v_sample->>'configuration_schema_version')::integer,(v_sample->>'configuration_revision')::integer)
      returning * into v_row;
      client_sample_id:=v_row.client_sample_id; acknowledgment_id:=v_row.id; received_at:=v_row.received_at; idempotent_existing:=false; return next;

    else
      raise exception 'unsupported identifier' using errcode='22023';
    end if;
  end loop;
end; $$;

revoke all on function public.submit_healthkit_samples(uuid,text,uuid,jsonb) from public, anon;
grant execute on function public.submit_healthkit_samples(uuid,text,uuid,jsonb) to authenticated;

