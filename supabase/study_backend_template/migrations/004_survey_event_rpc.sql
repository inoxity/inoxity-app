-- STUDY DATA BACKEND ONLY. The RPC binds every event to auth.uid(), its enrollment,
-- and this backend's immutable identity. Direct table writes remain unavailable.
-- p_event_time_zone is p_-prefixed (unlike this function's other, pre-existing params) to match
-- the app's own param name and avoid any future bare-reference collision with
-- survey_events.event_time_zone, the same defensive pattern as update_sleep_schedule/
-- update_participant_identifier in 002_study_data_rls_and_rpcs.sql.
create or replace function public.submit_survey_event(
 client_event_id text, expected_backend_id text, expected_stable_study_id text,
 enrollment_id text, survey_id text, occurrence_id text, event_type text,
 event_timestamp text, scheduled_for text, opened_at text default null,
 completed_at text default null, configuration_schema_version integer default 0,
 configuration_revision integer default 0, event_source text default 'restoration',
 app_version text default 'unknown', p_event_time_zone text default null)
returns table(acknowledgment_id uuid, received_at timestamptz, idempotent_existing boolean)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare m public.study_backend_metadata%rowtype; p public.participants%rowtype;
 e public.study_enrollments%rowtype; existing public.survey_events%rowtype; inserted boolean := false;
begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id
    then raise exception 'backend_identity_mismatch'; end if;
 select * into p from public.participants where auth_user_id=auth.uid();
 if not found then raise exception 'participant_missing'; end if;
 select * into e from public.study_enrollments where id=enrollment_id::uuid and participant_id=p.id;
 if not found then raise exception 'ownership_denied'; end if;
 if exists(select 1 from public.withdrawal_requests w where w.enrollment_id=e.id and w.requested_at < event_timestamp::timestamptz)
    then raise exception 'event_after_withdrawal'; end if;
 if event_type='completed' and not exists(select 1 from public.survey_events s where s.enrollment_id=e.id and s.occurrence_id=submit_survey_event.occurrence_id and s.event_type='opened')
    then raise exception 'opened_event_required'; end if;
 insert into public.survey_events(client_event_id,participant_id,enrollment_id,survey_id,occurrence_id,event_type,
   event_timestamp,scheduled_for,opened_at,completed_at,event_time_zone,configuration_schema_version,configuration_revision,event_source,app_version)
 values(client_event_id,p.id,e.id,survey_id,occurrence_id,event_type,event_timestamp::timestamptz,scheduled_for::timestamptz,
   opened_at::timestamptz,completed_at::timestamptz,p_event_time_zone,configuration_schema_version,configuration_revision,event_source,app_version)
 on conflict(client_event_id) do nothing returning true into inserted;
 select * into existing from public.survey_events s where s.client_event_id=submit_survey_event.client_event_id;
 if not found or existing.participant_id<>p.id or existing.enrollment_id<>e.id or existing.survey_id<>submit_survey_event.survey_id
    or existing.occurrence_id<>submit_survey_event.occurrence_id or existing.event_type<>submit_survey_event.event_type
    or existing.event_timestamp<>submit_survey_event.event_timestamp::timestamptz then raise exception 'conflicting_idempotency_key'; end if;
 return query select existing.id,existing.received_at,not inserted;
end $$;

revoke all on function public.submit_survey_event(text,text,text,text,text,text,text,text,text,text,text,integer,integer,text,text,text) from public;
grant execute on function public.submit_survey_event(text,text,text,text,text,text,text,text,text,text,text,integer,integer,text,text,text) to authenticated;
