-- STUDY DATA BACKEND ONLY
-- Records the metadata row for a media file the app already uploaded
-- directly to the user-uploads Storage bucket (see 007's RLS policies for
-- that leg). Ownership/identity checks mirror every other RPC in this
-- template; idempotent on storage_path since the app may retry a metadata
-- write after a transient failure without re-uploading the file.

create or replace function public.submit_media_upload(
  expected_backend_id text, expected_stable_study_id text, enrollment_id text,
  storage_path text, mime_type text, category_id text, bytes bigint,
  duration_seconds numeric default null, represented_date date default null,
  configuration_schema_version integer default 0, configuration_revision integer default 0
) returns table(id uuid, received_at timestamptz)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  m public.study_backend_metadata%rowtype; p public.participants%rowtype; v_existing public.media_uploads%rowtype; v_row public.media_uploads%rowtype;
begin
  if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
  select * into m from public.study_backend_metadata where singleton;
  if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
  if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id then raise exception 'backend_identity_mismatch'; end if;
  select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
  if not exists(select 1 from public.study_enrollments e where e.id=enrollment_id::uuid and e.participant_id=p.id)
     then raise exception 'enrollment_ownership_denied' using errcode='42501'; end if;
  -- storage_path's own prefix (see 007's RLS policies) already ties it to
  -- this auth.uid(), so this is belt-and-suspenders against a
  -- mismatched/forged path being recorded under the wrong participant.
  if split_part(storage_path, '/', 1) <> auth.uid()::text then raise exception 'ownership_denied' using errcode='42501'; end if;

  select * into v_existing from public.media_uploads t where t.storage_path = submit_media_upload.storage_path;
  if found then
    if v_existing.participant_id <> p.id or v_existing.enrollment_id <> enrollment_id::uuid
       or v_existing.stable_study_id <> expected_stable_study_id
       or v_existing.mime_type <> submit_media_upload.mime_type or v_existing.bytes <> submit_media_upload.bytes
       or v_existing.category_id <> submit_media_upload.category_id
       or v_existing.duration_seconds is distinct from submit_media_upload.duration_seconds
       or v_existing.represented_date is distinct from submit_media_upload.represented_date
       or v_existing.configuration_schema_version <> submit_media_upload.configuration_schema_version
       or v_existing.configuration_revision <> submit_media_upload.configuration_revision
    then raise exception 'conflicting_duplicate_identity' using errcode='23505'; end if;
    return query select v_existing.id, v_existing.received_at; return;
  end if;

  insert into public.media_uploads(participant_id,enrollment_id,stable_study_id,storage_path,mime_type,bytes,category_id,duration_seconds,represented_date,configuration_schema_version,configuration_revision)
  values(p.id,enrollment_id::uuid,expected_stable_study_id,submit_media_upload.storage_path,submit_media_upload.mime_type,submit_media_upload.bytes,submit_media_upload.category_id,submit_media_upload.duration_seconds,submit_media_upload.represented_date,submit_media_upload.configuration_schema_version,submit_media_upload.configuration_revision)
  returning * into v_row;
  return query select v_row.id, v_row.received_at;
end $$;

revoke all on function public.submit_media_upload(text,text,text,text,text,text,bigint,numeric,date,integer,integer) from public, anon;
grant execute on function public.submit_media_upload(text,text,text,text,text,text,bigint,numeric,date,integer,integer) to authenticated;
