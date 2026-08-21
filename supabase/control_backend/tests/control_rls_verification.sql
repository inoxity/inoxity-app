-- CONTROL BACKEND ONLY — run after migrations 001-002 in a disposable transaction.
-- Uses only fake Development rows and rolls back every change.
begin;

do $$
declare unexpected text;
begin
  select string_agg(tablename, ', ' order by tablename) into unexpected
  from pg_tables where schemaname='public' and tablename not in ('studies','study_backends');
  if unexpected is not null then raise exception 'unexpected Control Backend application tables: %', unexpected; end if;
  if to_regprocedure('public.resolve_study_bootstrap(text)') is null then raise exception 'bootstrap RPC missing'; end if;
  if not (select relrowsecurity from pg_class where oid='public.studies'::regclass) then raise exception 'studies RLS disabled'; end if;
  if not (select relrowsecurity from pg_class where oid='public.study_backends'::regclass) then raise exception 'study_backends RLS disabled'; end if;
  if has_table_privilege('authenticated','public.studies','select')
     or has_table_privilege('authenticated','public.study_backends','select') then raise exception 'participant role can list control tables'; end if;
  if has_table_privilege('authenticated','public.studies','insert') or has_table_privilege('authenticated','public.studies','update')
     or has_table_privilege('authenticated','public.studies','delete') or has_table_privilege('authenticated','public.study_backends','insert')
     or has_table_privilege('authenticated','public.study_backends','update') or has_table_privilege('authenticated','public.study_backends','delete')
     then raise exception 'participant role can modify control tables'; end if;
  if not has_function_privilege('authenticated','public.resolve_study_bootstrap(text)','execute') then raise exception 'bootstrap RPC unavailable'; end if;
end $$;

insert into public.study_backends(id,backend_slug,environment,supabase_url,supabase_anon_key,descriptor_revision,is_active)
values
 ('10000000-0000-0000-0000-000000000001','verification-active','Development','https://active.invalid.supabase.co',repeat('a',24),1,true),
 ('10000000-0000-0000-0000-000000000002','verification-inactive','Development','https://inactive.invalid.supabase.co',repeat('b',24),1,false);
insert into public.studies(stable_study_id,study_code,configuration_schema_version,configuration_revision,configuration_json,study_backend_id,is_active)
values
 ('verification-active','VERIFY_ACTIVE',5,1,'{}','10000000-0000-0000-0000-000000000001',true),
 ('verification-study-inactive','VERIFY_STUDY_OFF',5,1,'{}','10000000-0000-0000-0000-000000000001',false),
 ('verification-backend-inactive','VERIFY_BACKEND_OFF',5,1,'{}','10000000-0000-0000-0000-000000000002',true);

set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000099',true);

do $$ begin
  if (select count(*) from public.resolve_study_bootstrap(' verify_active ')) <> 1 then raise exception 'exact active-code bootstrap failed'; end if;
  begin perform * from public.resolve_study_bootstrap('MISSING_CODE'); raise exception 'invalid code unexpectedly resolved';
  exception when others then if sqlerrm not like '%study_not_found%' then raise; end if; end;
  begin perform * from public.resolve_study_bootstrap('VERIFY_STUDY_OFF'); raise exception 'inactive study unexpectedly resolved';
  exception when others then if sqlerrm not like '%study_inactive%' then raise; end if; end;
  begin perform * from public.resolve_study_bootstrap('VERIFY_BACKEND_OFF'); raise exception 'inactive backend unexpectedly resolved';
  exception when others then if sqlerrm not like '%study_backend_unavailable%' then raise; end if; end;
end $$;

rollback;
