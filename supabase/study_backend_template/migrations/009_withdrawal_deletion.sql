-- ================================================================
-- STUDY DATA BACKEND ONLY — apply to exactly one Study Backend, after 001-008.
--
-- submit_withdrawal_request (002) only ever inserted a row recording the
-- participant's withdrawal_choice — regardless of 'keepExistingData' vs
-- 'deleteExistingData', nothing anywhere in 001-008 ever deletes a row.
-- This migration makes 'deleteExistingData' genuinely delete the
-- participant's data, while keeping an anonymized audit record (a
-- withdrawal_requests row survives with participant_id/enrollment_id
-- nulled and processed_at set) rather than a traceless purge. Also fixes a
-- related bug: 'keepExistingData' never transitioned study_enrollments.status
-- to 'withdrawn' either — it now does.
--
-- Also returns the exact media_uploads.storage_path values it deleted, so
-- the Swift client can delete the matching Supabase Storage objects too —
-- Postgres has no way to reach Storage directly, deleting the metadata row
-- alone would leave the actual uploaded file behind.
--
-- IN params are p_-prefixed (client_event_id/enrollment_id/withdrawal_choice/
-- requested_at, but NOT expected_backend_id/expected_stable_study_id, which
-- don't collide with anything) because each one also names an actual column
-- on withdrawal_requests — same defensive pattern already used by
-- register_study_enrollment (p_enrollment_attempt_id) and
-- update_sleep_schedule (p_wake_time/p_bed_time) in 002: a bare occurrence
-- of a parameter name that also matches a column name, anywhere a statement
-- has that table in scope, makes plpgsql treat the reference as ambiguous
-- (42702) — this used to only bite the one INSERT statement below (which
-- worked fine unprefixed), but adding the idempotent-retry SELECT under it
-- gave plpgsql a second table-scoped statement to trip over, surfacing the
-- same latent collision. Renaming removes the ambiguity everywhere at once
-- instead of trying to out-guess which specific statement triggers it.
--
-- The Swift app's RPC call must send these same p_-prefixed keys — see
-- SupabaseRepositories.swift's Params struct for submit(_:remoteEnrollmentID:).
--
-- The RETURNS TABLE shape also grows one column (deleted_storage_paths), so
-- this drops the function first — `create or replace function` cannot
-- change an existing function's return type in place.
-- ================================================================

-- withdrawal_requests must be able to outlive the participant/enrollment
-- rows it references, once those are deleted — participant_id was NOT NULL
-- with a plain (non-cascading) FK, which would otherwise block deletion.
alter table public.withdrawal_requests alter column participant_id drop not null;
alter table public.withdrawal_requests drop constraint if exists withdrawal_requests_participant_id_fkey;
alter table public.withdrawal_requests add constraint withdrawal_requests_participant_id_fkey
  foreign key (participant_id) references public.participants(id) on delete set null;
alter table public.withdrawal_requests drop constraint if exists withdrawal_requests_enrollment_id_fkey;
alter table public.withdrawal_requests add constraint withdrawal_requests_enrollment_id_fkey
  foreign key (enrollment_id) references public.study_enrollments(id) on delete set null;

drop function if exists public.submit_withdrawal_request(text,text,text,text,text,text);

create function public.submit_withdrawal_request(p_client_event_id text, expected_backend_id text,
 expected_stable_study_id text, p_withdrawal_choice text, p_requested_at text, p_enrollment_id text default null)
returns table(request_id uuid, deleted_storage_paths text[])
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  m public.study_backend_metadata%rowtype;
  p public.participants%rowtype;
  r public.withdrawal_requests%rowtype;
  existing public.withdrawal_requests%rowtype;
  v_paths text[] := '{}';
begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;

 -- Idempotent short-circuit for a retry of an already-fully-processed request:
 -- once deletion has actually happened, the participant/enrollment rows this
 -- function would otherwise look up are legitimately gone, so re-validating
 -- identity/ownership below would incorrectly fail a harmless retry. No
 -- paths returned here — they were already returned (and presumably already
 -- deleted client-side) on the original successful call.
 select * into existing from public.withdrawal_requests where client_event_id = p_client_event_id::uuid;
 if found and existing.processed_at is not null then
   return query select existing.id, '{}'::text[]; return;
 end if;

 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id then raise exception 'backend_identity_mismatch'; end if;
 select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
 if p_enrollment_id is null then raise exception 'enrollment_missing' using errcode='22023'; end if;
 if not exists(select 1 from public.study_enrollments e where e.id=p_enrollment_id::uuid and e.participant_id=p.id)
    then raise exception 'enrollment_ownership_denied' using errcode='42501'; end if;

 insert into public.withdrawal_requests(client_event_id,participant_id,enrollment_id,withdrawal_choice,requested_at)
 values(p_client_event_id::uuid,p.id,p_enrollment_id::uuid,p_withdrawal_choice,p_requested_at::timestamptz) on conflict(client_event_id) do nothing;
 select * into r from public.withdrawal_requests where client_event_id = p_client_event_id::uuid;
 if r.participant_id is distinct from p.id or r.enrollment_id is distinct from p_enrollment_id::uuid
    or r.withdrawal_choice <> p_withdrawal_choice
    or r.requested_at <> p_requested_at::timestamptz
    then raise exception 'conflicting_idempotency_key' using errcode='23505'; end if;

 if r.withdrawal_choice = 'deleteExistingData' then
   -- Capture storage_path values BEFORE the cascade removes the media_uploads rows —
   -- deleting study_enrollments below cascades media_uploads away along with everything else.
   select coalesce(array_agg(storage_path), '{}') into v_paths
     from public.media_uploads where enrollment_id = r.enrollment_id;
   delete from public.survey_events where enrollment_id = r.enrollment_id; -- no on delete cascade declared on this table (001/003)
   delete from public.study_enrollments where id = r.enrollment_id; -- cascades all 10 HealthKit tables + media_uploads (005/007)
   update public.withdrawal_requests set processed_at = now() where id = r.id;
   delete from public.participants where id = p.id; -- safe: withdrawal_requests' FK is now on delete set null
 else
   update public.study_enrollments set status = 'withdrawn' where id = r.enrollment_id;
   update public.withdrawal_requests set processed_at = now() where id = r.id;
 end if;

 return query select r.id, v_paths;
end $$;

revoke all on function public.submit_withdrawal_request(text,text,text,text,text,text) from public, anon;
grant execute on function public.submit_withdrawal_request(text,text,text,text,text,text) to authenticated;
