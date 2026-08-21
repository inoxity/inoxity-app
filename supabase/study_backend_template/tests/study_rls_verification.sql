-- STUDY DATA BACKEND ONLY — base schema and two-user verification.
-- Run after migrations 001-011 with one active metadata row. All fake rows roll back.
begin;

do $$ begin
 if to_regclass('public.studies') is not null or to_regclass('public.study_backends') is not null then raise exception 'control table exists in Study Backend'; end if;
 if (select count(*) from public.study_backend_metadata) <> 1 then raise exception 'exactly one Study Backend identity is required'; end if;
 if not (select is_active from public.study_backend_metadata where singleton) then raise exception 'verification requires an active Study Backend'; end if;
 if not (select relrowsecurity from pg_class where oid='public.participants'::regclass)
    or not (select relrowsecurity from pg_class where oid='public.study_enrollments'::regclass)
    or not (select relrowsecurity from pg_class where oid='public.withdrawal_requests'::regclass) then raise exception 'base Study Backend RLS disabled'; end if;
 if has_table_privilege('authenticated','public.participants','insert') or has_table_privilege('authenticated','public.participants','update')
    or has_table_privilege('authenticated','public.study_enrollments','insert') or has_table_privilege('authenticated','public.study_enrollments','update')
    or has_table_privilege('authenticated','public.withdrawal_requests','insert') or has_table_privilege('authenticated','public.withdrawal_requests','update')
    or has_table_privilege('authenticated','public.study_backend_metadata','update') then raise exception 'participant role has unsafe direct write privilege'; end if;
end $$;

insert into public.participants(id,auth_user_id) values
 ('20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000011'),
 ('20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000022');
insert into public.study_enrollments(id,participant_id,participant_identifier,enrollment_attempt_id,installation_id,configuration_schema_version,configuration_revision)
values('20000000-0000-0000-0000-000000000102','20000000-0000-0000-0000-000000000002','FAKE-B','20000000-0000-0000-0000-000000000202','20000000-0000-0000-0000-000000000302',5,1);

set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; a_enrollment uuid; first_request uuid; retry_request uuid; reenrolled_id uuid; reenrolled_status text; updated_identifier text; begin
 select * into m from public.study_backend_metadata where singleton;
 if exists(select 1 from public.participants where auth_user_id='20000000-0000-0000-0000-000000000022') then raise exception 'A can read B participant'; end if;
 if exists(select 1 from public.study_enrollments where id='20000000-0000-0000-0000-000000000102') then raise exception 'A can read B enrollment'; end if;
 perform * from public.ensure_participant();
 perform * from public.register_study_enrollment(m.backend_instance_id::text,m.stable_study_id,m.expected_study_code,'FAKE-A','20000000-0000-0000-0000-000000000201','20000000-0000-0000-0000-000000000301',5,1);
 select id into a_enrollment from public.study_enrollments where participant_id='20000000-0000-0000-0000-000000000001';
 perform * from public.register_study_enrollment(m.backend_instance_id::text,m.stable_study_id,m.expected_study_code,'FAKE-A','20000000-0000-0000-0000-000000000201','20000000-0000-0000-0000-000000000301',5,1);
 begin perform * from public.register_study_enrollment(m.backend_instance_id::text,m.stable_study_id,m.expected_study_code,'CHANGED','20000000-0000-0000-0000-000000000201','20000000-0000-0000-0000-000000000301',5,1); raise exception 'conflicting enrollment retry accepted'; exception when unique_violation then null; end;
 begin perform * from public.register_study_enrollment('20000000-0000-0000-0000-000000000099',m.stable_study_id,m.expected_study_code,'FAKE-A','20000000-0000-0000-0000-000000000211','20000000-0000-0000-0000-000000000301',5,1); raise exception 'wrong backend accepted'; exception when others then if sqlerrm not like '%backend_identity_mismatch%' then raise; end if; end;
 begin perform * from public.register_study_enrollment(m.backend_instance_id::text,'wrong-study',m.expected_study_code,'FAKE-A','20000000-0000-0000-0000-000000000212','20000000-0000-0000-0000-000000000301',5,1); raise exception 'wrong study accepted'; exception when others then if sqlerrm not like '%backend_identity_mismatch%' then raise; end if; end;
 begin perform * from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000401',m.backend_instance_id::text,m.stable_study_id,'keepExistingData','2026-01-01T00:00:00Z','20000000-0000-0000-0000-000000000102'); raise exception 'foreign enrollment withdrawal accepted'; exception when insufficient_privilege then null; end;
 begin perform * from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000402',m.backend_instance_id::text,m.stable_study_id,'keepExistingData','2026-01-01T00:00:00Z','20000000-0000-0000-0000-000000000999'); raise exception 'missing enrollment withdrawal accepted'; exception when insufficient_privilege then null; end;
 begin perform * from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000403',m.backend_instance_id::text,'wrong-study','keepExistingData','2026-01-01T00:00:00Z',a_enrollment::text); raise exception 'wrong study withdrawal accepted'; exception when others then if sqlerrm not like '%backend_identity_mismatch%' then raise; end if; end;
 select request_id into first_request from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000404',m.backend_instance_id::text,m.stable_study_id,'keepExistingData','2026-01-01T00:00:00Z',a_enrollment::text);
 select request_id into retry_request from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000404',m.backend_instance_id::text,m.stable_study_id,'keepExistingData','2026-01-01T00:00:00Z',a_enrollment::text);
 if first_request <> retry_request then raise exception 'withdrawal retry not idempotent'; end if;
 begin perform * from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000404',m.backend_instance_id::text,m.stable_study_id,'deleteExistingData','2026-01-01T00:00:00Z',a_enrollment::text); raise exception 'conflicting withdrawal retry accepted'; exception when unique_violation then null; end;
 -- 010: re-enrolling after a keepExistingData withdrawal reactivates the
 -- same enrollment row (status back to 'active') instead of staying
 -- withdrawn forever or inserting a duplicate row for this participant.
 select enrollment_id, status into reenrolled_id, reenrolled_status
   from public.register_study_enrollment(m.backend_instance_id::text,m.stable_study_id,m.expected_study_code,'FAKE-A-REENROLLED','20000000-0000-0000-0000-000000000205','20000000-0000-0000-0000-000000000301',5,1);
 if reenrolled_status <> 'active' then raise exception 'reenrollment after keep-data withdrawal did not reactivate'; end if;
 if reenrolled_id <> a_enrollment then raise exception 'reenrollment created a duplicate row instead of reactivating the original'; end if;
 if (select count(*) from public.study_enrollments where participant_id='20000000-0000-0000-0000-000000000001') <> 1 then raise exception 'reenrollment left more than one enrollment row for the participant'; end if;
 -- 011: participant can correct their own participant_identifier post-enrollment.
 select participant_identifier into updated_identifier from public.update_participant_identifier(m.backend_instance_id::text,m.stable_study_id,'FAKE-A-CORRECTED');
 if updated_identifier <> 'FAKE-A-CORRECTED' then raise exception 'participant_identifier update did not apply'; end if;
 if (select participant_identifier from public.study_enrollments where id=a_enrollment) <> 'FAKE-A-CORRECTED' then raise exception 'participant_identifier update did not persist'; end if;
 begin perform * from public.update_participant_identifier(m.backend_instance_id::text,m.stable_study_id,'   '); raise exception 'blank participant_identifier accepted'; exception when others then if sqlerrm not like '%invalid_participant_identifier%' then raise; end if; end;
end $$;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000022',true);
do $$ begin
 if exists(select 1 from public.participants where auth_user_id='20000000-0000-0000-0000-000000000011') then raise exception 'B can read A participant'; end if;
 if exists(select 1 from public.study_enrollments where participant_id='20000000-0000-0000-0000-000000000001') then raise exception 'B can read A enrollment'; end if;
end $$;

reset role;
update public.study_backend_metadata set is_active=false where singleton;
set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; begin
 select * into m from public.study_backend_metadata where singleton;
 begin perform * from public.ensure_participant(); raise exception 'inactive ensure accepted'; exception when others then if sqlerrm not like '%study_backend_inactive%' then raise; end if; end;
 begin perform * from public.register_study_enrollment(m.backend_instance_id::text,m.stable_study_id,m.expected_study_code,'FAKE-A','20000000-0000-0000-0000-000000000221','20000000-0000-0000-0000-000000000301',5,1); raise exception 'inactive enrollment accepted'; exception when others then if sqlerrm not like '%study_backend_inactive%' then raise; end if; end;
 begin perform * from public.submit_withdrawal_request('20000000-0000-0000-0000-000000000405',m.backend_instance_id::text,m.stable_study_id,'keepExistingData','2026-01-01T00:00:00Z','20000000-0000-0000-0000-000000000102'); raise exception 'inactive withdrawal accepted'; exception when others then if sqlerrm not like '%study_backend_inactive%' then raise; end if; end;
end $$;

rollback;
