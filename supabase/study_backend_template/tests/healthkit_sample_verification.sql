-- STUDY DATA BACKEND ONLY — run after migrations 001-006 with disposable fake participants.
begin;
do $$ begin
 if not (select relrowsecurity from pg_class where oid='public.healthkit_samples'::regclass) then raise exception 'HealthKit RLS disabled'; end if;
 if has_table_privilege('anon','public.healthkit_samples','insert') or has_table_privilege('authenticated','public.healthkit_samples','insert')
    or has_table_privilege('authenticated','public.healthkit_samples','update') or has_table_privilege('authenticated','public.healthkit_samples','delete')
    then raise exception 'direct HealthKit mutation allowed'; end if;
 if not has_function_privilege('authenticated','public.submit_healthkit_samples(uuid,text,uuid,jsonb)','execute') then raise exception 'HealthKit RPC unavailable'; end if;
end $$;

insert into public.participants(id,auth_user_id) values
 ('40000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000011'),
 ('40000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000022');
insert into public.study_enrollments(id,participant_id,participant_identifier,enrollment_attempt_id,installation_id,configuration_schema_version,configuration_revision) values
 ('40000000-0000-0000-0000-000000000101','40000000-0000-0000-0000-000000000001','FAKE-A','40000000-0000-0000-0000-000000000201','40000000-0000-0000-0000-000000000301',5,1),
 ('40000000-0000-0000-0000-000000000102','40000000-0000-0000-0000-000000000002','FAKE-B','40000000-0000-0000-0000-000000000202','40000000-0000-0000-0000-000000000302',5,1);
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; sample jsonb; first_id uuid; retry_id uuid; begin
 select * into m from public.study_backend_metadata where singleton;
 sample := jsonb_build_array(jsonb_build_object('client_sample_id','healthkit.fake.40000000-0000-0000-0000-000000000501','sample_uuid','40000000-0000-0000-0000-000000000501','health_type_identifier','stepCount','sample_kind','quantity','sample_start','2026-01-01T00:00:00Z','sample_end','2026-01-01T01:00:00Z','numeric_value',100,'canonical_unit','count','configuration_schema_version',5,'configuration_revision',1));
 begin perform * from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000102',sample); raise exception 'foreign HealthKit enrollment accepted'; exception when insufficient_privilege then null; end;
 begin perform * from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',jsonb_set(sample,'{0,health_type_identifier}','"unsupported"')); raise exception 'unsupported metric accepted'; exception when invalid_parameter_value then null; end;
 begin perform * from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',jsonb_set(sample,'{0,canonical_unit}','"kcal"')); raise exception 'invalid unit accepted'; exception when invalid_parameter_value then null; end;
 select acknowledgment_id into first_id from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',sample);
 select acknowledgment_id into retry_id from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',sample);
 if first_id<>retry_id then raise exception 'HealthKit retry not idempotent'; end if;
 begin perform * from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',jsonb_set(sample,'{0,numeric_value}','101')); raise exception 'conflicting HealthKit retry accepted'; exception when unique_violation then null; end;
end $$;
reset role;
update public.study_backend_metadata set is_active=false where singleton;
set local role authenticated;
select set_config('request.jwt.claim.sub','40000000-0000-0000-0000-000000000011',true);
do $$ declare m public.study_backend_metadata%rowtype; sample jsonb; begin select * into m from public.study_backend_metadata where singleton;
 sample := jsonb_build_array(jsonb_build_object('client_sample_id','healthkit.fake.40000000-0000-0000-0000-000000000502','sample_uuid','40000000-0000-0000-0000-000000000502','health_type_identifier','stepCount','sample_kind','quantity','sample_start','2026-01-01T00:00:00Z','sample_end','2026-01-01T01:00:00Z','numeric_value',100,'canonical_unit','count','configuration_schema_version',5,'configuration_revision',1));
 begin perform * from public.submit_healthkit_samples(m.backend_instance_id,m.stable_study_id,'40000000-0000-0000-0000-000000000101',sample); raise exception 'inactive HealthKit write accepted'; exception when others then if sqlerrm not like '%study_backend_inactive%' then raise; end if; end;
end $$;
rollback;
