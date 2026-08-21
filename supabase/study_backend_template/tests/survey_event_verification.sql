-- STUDY DATA BACKEND ONLY — run after migrations 001-004 in a disposable transaction.
begin;
do $$ begin
 if not exists(select 1 from pg_class where relname='survey_events' and relrowsecurity) then
   raise exception 'survey_events RLS must be enabled';
 end if;
 if has_table_privilege('anon','public.survey_events','insert') or has_table_privilege('authenticated','public.survey_events','insert') then
   raise exception 'direct survey event inserts must remain revoked';
 end if;
 if not exists(select 1 from pg_proc where proname='submit_survey_event') then
   raise exception 'submit_survey_event RPC missing';
 end if;
 if has_table_privilege('authenticated','public.survey_events','update') or has_table_privilege('authenticated','public.survey_events','delete') then
   raise exception 'direct survey event mutation must remain revoked';
 end if;
end $$;

insert into public.participants(id,auth_user_id) values
 ('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000011'),
 ('30000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000022');
insert into public.study_enrollments(id,participant_id,participant_identifier,enrollment_attempt_id,installation_id,configuration_schema_version,configuration_revision) values
 ('30000000-0000-0000-0000-000000000101','30000000-0000-0000-0000-000000000001','FAKE-A','30000000-0000-0000-0000-000000000201','30000000-0000-0000-0000-000000000301',5,1),
 ('30000000-0000-0000-0000-000000000102','30000000-0000-0000-0000-000000000002','FAKE-B','30000000-0000-0000-0000-000000000202','30000000-0000-0000-0000-000000000302',5,1);
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; first_id uuid; retry_id uuid; begin
 select * into m from public.study_backend_metadata where singleton;
 begin perform * from public.submit_survey_event('survey-event.foreign.opened',m.backend_instance_id::text,m.stable_study_id,'30000000-0000-0000-0000-000000000102','survey','foreign','opened','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z',null,5,1,'presentation','test'); raise exception 'foreign survey enrollment accepted'; exception when others then if sqlerrm not like '%ownership_denied%' then raise; end if; end;
 select acknowledgment_id into first_id from public.submit_survey_event('survey-event.owned.opened',m.backend_instance_id::text,m.stable_study_id,'30000000-0000-0000-0000-000000000101','survey','owned','opened','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z',null,5,1,'presentation','test');
 select acknowledgment_id into retry_id from public.submit_survey_event('survey-event.owned.opened',m.backend_instance_id::text,m.stable_study_id,'30000000-0000-0000-0000-000000000101','survey','owned','opened','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z',null,5,1,'presentation','test');
 if first_id<>retry_id then raise exception 'survey retry not idempotent'; end if;
 begin perform * from public.submit_survey_event('survey-event.owned.opened',m.backend_instance_id::text,m.stable_study_id,'30000000-0000-0000-0000-000000000101','changed','owned','opened','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z',null,5,1,'presentation','test'); raise exception 'conflicting survey retry accepted'; exception when others then if sqlerrm not like '%conflicting_idempotency_key%' then raise; end if; end;
end $$;
reset role;
update public.study_backend_metadata set is_active=false where singleton;
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; begin select * into m from public.study_backend_metadata where singleton;
 begin perform * from public.submit_survey_event('survey-event.inactive.opened',m.backend_instance_id::text,m.stable_study_id,'30000000-0000-0000-0000-000000000101','survey','inactive','opened','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z','2026-01-01T09:00:00Z',null,5,1,'presentation','test'); raise exception 'inactive survey write accepted'; exception when others then if sqlerrm not like '%study_backend_inactive%' then raise; end if; end;
end $$;
rollback;
