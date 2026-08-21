-- STUDY DATA BACKEND ONLY — apply to exactly one Study Backend.
-- Real remote media upload, matching the pre-dashboard app's working
-- implementation (a `media_uploads` table + a `user-uploads` Storage
-- bucket) — the current app's media feature only stores selections
-- locally; this is what a study's Data Backend needs to actually receive
-- them. Only apply this file (and 008) if the study has media enabled.

create table public.media_uploads (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references public.participants(id) on delete cascade,
  enrollment_id uuid not null references public.study_enrollments(id) on delete cascade,
  stable_study_id text not null check (char_length(stable_study_id) between 1 and 100),
  -- "<auth.uid()>/<category_id>/<draft-id>.<ext>" — the RLS policies below on
  -- storage.objects rely on this exact prefix convention to scope each
  -- participant to only their own files.
  storage_path text not null unique check (char_length(storage_path) between 1 and 500),
  mime_type text not null check (char_length(mime_type) between 1 and 100),
  bytes bigint not null check (bytes > 0),
  category_id text not null check (char_length(category_id) between 1 and 100),
  duration_seconds numeric check (duration_seconds is null or duration_seconds >= 0),
  -- The calendar date this media item represents (e.g. "yesterday's Screen
  -- Time report"), distinct from received_at/created_at (when it was
  -- uploaded). New in this schema — no pre-dashboard-app equivalent.
  represented_date date,
  configuration_schema_version integer not null check (configuration_schema_version > 0),
  configuration_revision integer not null check (configuration_revision > 0),
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.media_uploads enable row level security;
revoke all on public.media_uploads from anon, authenticated;

comment on table public.media_uploads is
'STUDY DATA BACKEND ONLY. Metadata for files uploaded to the user-uploads Storage bucket; the file itself lives in Storage, this only records where and what it is.';

-- Storage bucket + RLS. Private (not public); every read/write is scoped to
-- the participant's own auth.uid()-prefixed path via storage.foldername,
-- mirroring the RPC-gated posture of every other table in this template
-- even though Storage access itself isn't RPC-mediated (Supabase Storage
-- doesn't support RPC-style writes — RLS on storage.objects is the
-- equivalent gate here).
insert into storage.buckets (id, name, public)
values ('user-uploads', 'user-uploads', false)
on conflict (id) do nothing;

create policy "Participants can upload their own files"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'user-uploads' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Participants can read their own files"
  on storage.objects
  for select
  to authenticated
  using (bucket_id = 'user-uploads' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Participants can delete their own files"
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'user-uploads' and (storage.foldername(name))[1] = auth.uid()::text);
