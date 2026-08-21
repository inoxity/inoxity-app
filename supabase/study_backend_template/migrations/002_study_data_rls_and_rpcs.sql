-- ================================================================
-- STUDY DATA BACKEND ONLY — apply to exactly one Study Backend.
-- All RPCs bind writes to auth.uid() and the immutable backend identity.
-- ================================================================
alter table public.study_backend_metadata enable row level security;
alter table public.participants enable row level security;
alter table public.study_enrollments enable row level security;
alter table public.withdrawal_requests enable row level security;
revoke all on all tables in schema public from anon, authenticated;
create policy participant_owns_self on public.participants for select to authenticated using (auth_user_id = auth.uid());
create policy participant_owns_enrollment on public.study_enrollments for select to authenticated
 using (participant_id in (select p.id from public.participants p where p.auth_user_id = auth.uid()));
create policy participant_owns_withdrawal on public.withdrawal_requests for select to authenticated
 using (participant_id in (select p.id from public.participants p where p.auth_user_id = auth.uid()));

create or replace function public.get_study_backend_identity()
returns table (backend_instance_id uuid, stable_study_id text, expected_study_code text,
 supported_configuration_schema_version integer, is_active boolean)
language plpgsql security definer set search_path = pg_catalog, public as $$ begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 return query select m.backend_instance_id,m.stable_study_id,m.expected_study_code,m.supported_configuration_schema_version,m.is_active from public.study_backend_metadata m where m.singleton;
end $$;

create or replace function public.ensure_participant()
returns table (participant_id uuid, created_at timestamptz)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare p public.participants%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 if not exists(select 1 from public.study_backend_metadata m where m.singleton and m.is_active)
    then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 insert into public.participants(auth_user_id) values(auth.uid()) on conflict(auth_user_id) do nothing;
 select * into p from public.participants where auth_user_id=auth.uid();
 return query select p.id,p.created_at;
end $$;

create or replace function public.register_study_enrollment(expected_backend_id text, expected_stable_study_id text,
 expected_study_code text, participant_identifier text, p_enrollment_attempt_id text, installation_id text,
 configuration_schema_version integer, configuration_revision integer)
-- Output columns are named enrolled_* (not configuration_schema_version/
-- configuration_revision) because plpgsql shares one namespace between IN
-- parameters and `returns table` columns — reusing the IN parameter names
-- here throws 42P13 "parameter name used more than once". return query
-- matches by position, not name, so this doesn't change the insert/select
-- logic below, only the two `EnrollmentRow.CodingKeys` raw values in
-- SupabaseRepositories.swift that decode this RPC's response.
-- Parameter is p_enrollment_attempt_id (not enrollment_attempt_id) because it
-- also appears in `on conflict(enrollment_attempt_id)` below, a position that
-- can't be qualified — any bare occurrence there makes plpgsql treat the
-- whole statement as ambiguous (42702) against the same-named table column.
returns table (enrollment_id uuid, participant_id uuid, status text, enrolled_at timestamptz,
 enrolled_schema_version integer, enrolled_revision integer)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare m public.study_backend_metadata%rowtype; p public.participants%rowtype; e public.study_enrollments%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id
    or m.expected_study_code <> upper(trim(expected_study_code)) or m.supported_configuration_schema_version <> configuration_schema_version then raise exception 'backend_identity_mismatch'; end if;
 select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
 -- study_enrollments has a separate unique(participant_id) constraint besides
 -- enrollment_attempt_id's, so a participant retrying with a fresh attempt id
 -- (e.g. local app state was reset but the same anonymous session persisted)
 -- would otherwise hit a raw unique-violation instead of succeeding. Make
 -- registration idempotent per participant: return the existing row if found.
 select * into e from public.study_enrollments where study_enrollments.participant_id = p.id;
 if found then
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

-- Mirrors the pre-dashboard app's participants.bed_time/wake_time columns —
-- called from the app whenever the participant sets/edits their sleep
-- schedule (initial onboarding step or later from Settings), so it's
-- visible/exportable server-side. IN params are p_-prefixed (not
-- wake_time/bed_time) for the same reason register_study_enrollment above
-- renames its OUT columns: plpgsql would otherwise treat a bare
-- wake_time/bed_time reference as ambiguous against the participants
-- column of the same name.
create or replace function public.update_sleep_schedule(expected_backend_id text, expected_stable_study_id text,
 p_wake_time text, p_bed_time text)
returns table(participant_id uuid, wake_time text, bed_time text)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare m public.study_backend_metadata%rowtype; p public.participants%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id then raise exception 'backend_identity_mismatch'; end if;
 if p_wake_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or p_bed_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'invalid_time_format' using errcode='22023'; end if;
 update public.participants set wake_time = p_wake_time, bed_time = p_bed_time
   where auth_user_id = auth.uid()
   returning * into p;
 if not found then raise exception 'participant_missing'; end if;
 return query select p.id, p.wake_time, p.bed_time;
end $$;

create or replace function public.submit_withdrawal_request(client_event_id text, expected_backend_id text,
 expected_stable_study_id text, withdrawal_choice text, requested_at text, enrollment_id text default null)
returns table(request_id uuid)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare m public.study_backend_metadata%rowtype; p public.participants%rowtype; r public.withdrawal_requests%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id then raise exception 'backend_identity_mismatch'; end if;
 select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
 if enrollment_id is null then raise exception 'enrollment_missing' using errcode='22023'; end if;
 if not exists(select 1 from public.study_enrollments e where e.id=enrollment_id::uuid and e.participant_id=p.id)
    then raise exception 'enrollment_ownership_denied' using errcode='42501'; end if;
 insert into public.withdrawal_requests(client_event_id,participant_id,enrollment_id,withdrawal_choice,requested_at)
 values(client_event_id::uuid,p.id,enrollment_id::uuid,withdrawal_choice,requested_at::timestamptz) on conflict(client_event_id) do nothing;
 select * into r from public.withdrawal_requests where withdrawal_requests.client_event_id=submit_withdrawal_request.client_event_id::uuid;
 if r.participant_id <> p.id or r.enrollment_id <> enrollment_id::uuid
    or r.withdrawal_choice <> submit_withdrawal_request.withdrawal_choice
    or r.requested_at <> submit_withdrawal_request.requested_at::timestamptz
    then raise exception 'conflicting_idempotency_key' using errcode='23505'; end if;
 return query select r.id;
end $$;

revoke all on function public.get_study_backend_identity(), public.ensure_participant() from public, anon;
revoke all on function public.register_study_enrollment(text,text,text,text,text,text,integer,integer) from public, anon;
revoke all on function public.update_sleep_schedule(text,text,text,text) from public, anon;
revoke all on function public.submit_withdrawal_request(text,text,text,text,text,text) from public, anon;
grant execute on function public.get_study_backend_identity(), public.ensure_participant() to authenticated;
grant execute on function public.register_study_enrollment(text,text,text,text,text,text,integer,integer) to authenticated;
grant execute on function public.update_sleep_schedule(text,text,text,text) to authenticated;
grant execute on function public.submit_withdrawal_request(text,text,text,text,text,text) to authenticated;
