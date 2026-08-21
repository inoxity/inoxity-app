-- ================================================================
-- STUDY DATA BACKEND ONLY — apply to exactly one Study Backend, after 001-009.
--
-- register_study_enrollment (002)'s idempotency check — added later in
-- ebd6ba3 purely to make a reinstall/retry with a fresh enrollment_attempt_id
-- succeed instead of hitting study_enrollments' unique(participant_id)
-- constraint as a raw 409 — looked up an existing enrollment by
-- participant_id and returned it as-is, regardless of status. That was fine
-- when nothing ever set status to 'withdrawn' (before 009). Once 009 made
-- 'keepExistingData' withdrawals actually set status='withdrawn', this same
-- lookup started handing back that withdrawn row on every later enrollment
-- attempt too — the client's `guard row.status == "active"` (Supabase-
-- Repositories.swift) then rejects it as BackendError.withdrawnEnrollment,
-- permanently blocking re-enrollment with no recovery path at all.
--
-- ('deleteExistingData' withdrawals were never affected by this — that path
-- deletes the participants row entirely, so a later enrollment attempt finds
-- no existing row and inserts a fresh one, same as first-time enrollment.)
--
-- This migration makes re-enrollment after a 'keepExistingData' withdrawal
-- work: if the existing row is 'active', behavior is unchanged (idempotent
-- retry, returned as-is). If it's 'withdrawn', UPDATE that same row back to
-- 'active' with the newly submitted enrollment_attempt_id/installation_id/
-- configuration_schema_version/configuration_revision/enrolled_at, rather
-- than inserting a second row — study_enrollments.participant_id is unique
-- (a second insert would fail outright), and reactivating the same row is
-- also what correctly keeps this enrollment_id's survey_events/HealthKit
-- history attached to the participant's new active period, exactly as
-- 'keepExistingData' promised when they withdrew.
--
-- Return type is unchanged from 002, so `create or replace function` applies
-- in place; no drop needed, and existing grants are preserved.
-- ================================================================

create or replace function public.register_study_enrollment(expected_backend_id text, expected_stable_study_id text,
 expected_study_code text, participant_identifier text, p_enrollment_attempt_id text, installation_id text,
 configuration_schema_version integer, configuration_revision integer)
returns table (enrollment_id uuid, participant_id uuid, status text, enrolled_at timestamptz,
 enrolled_schema_version integer, enrolled_revision integer)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare m public.study_backend_metadata%rowtype; p public.participants%rowtype; e public.study_enrollments%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id
    or m.expected_study_code <> upper(trim(expected_study_code)) or m.supported_configuration_schema_version <> configuration_schema_version then raise exception 'backend_identity_mismatch'; end if;
 select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
 select * into e from public.study_enrollments where study_enrollments.participant_id = p.id;
 if found and e.status = 'active' then
   -- Idempotent retry of an already-active enrollment: unchanged from 002.
   return query select e.id, e.participant_id, e.status, e.enrolled_at, e.configuration_schema_version, e.configuration_revision;
   return;
 end if;
 if found then
   -- Withdrawn: this is a re-enrollment. Reactivate this same row in place
   -- (see migration header) instead of inserting a second one.
   update public.study_enrollments set status='active', participant_identifier=register_study_enrollment.participant_identifier,
     enrollment_attempt_id=p_enrollment_attempt_id::uuid, installation_id=register_study_enrollment.installation_id::uuid,
     configuration_schema_version=register_study_enrollment.configuration_schema_version,
     configuration_revision=register_study_enrollment.configuration_revision, enrolled_at=now()
     where id = e.id returning * into e;
   return query select e.id, e.participant_id, e.status, e.enrolled_at, e.configuration_schema_version, e.configuration_revision;
   return;
 end if;
 insert into public.study_enrollments(participant_id,participant_identifier,enrollment_attempt_id,installation_id,configuration_schema_version,configuration_revision)
 values(p.id,register_study_enrollment.participant_identifier,p_enrollment_attempt_id::uuid,register_study_enrollment.installation_id::uuid,register_study_enrollment.configuration_schema_version,register_study_enrollment.configuration_revision)
 on conflict(enrollment_attempt_id) do nothing;
 select * into e from public.study_enrollments where study_enrollments.enrollment_attempt_id=p_enrollment_attempt_id::uuid;
 if e.participant_id <> p.id or e.participant_identifier <> register_study_enrollment.participant_identifier
    or e.installation_id <> register_study_enrollment.installation_id::uuid
    or e.configuration_schema_version <> register_study_enrollment.configuration_schema_version
    or e.configuration_revision <> register_study_enrollment.configuration_revision
    then raise exception 'conflicting_idempotency_key' using errcode='23505'; end if;
 return query select e.id,e.participant_id,e.status,e.enrolled_at,e.configuration_schema_version,e.configuration_revision;
end $$;
