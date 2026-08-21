-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
-- Researcher identity only. Participant identifiers and participant
-- records remain prohibited here (see 002_control_rls_and_rpcs.sql) —
-- the trigger below deliberately skips anonymous auth.users rows (the
-- ones participants' devices create via supabase.auth.signInAnonymously())
-- so no profiles row is ever created for a participant.
-- ================================================================
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  institution text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select, insert, update on public.profiles to authenticated;

create policy "Users can view their own profile"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Safety net only: the trigger below inserts as SECURITY DEFINER and
-- bypasses RLS, so this isn't required for signup to work, but keeps the
-- policy set complete in case a client-side insert is ever added later.
create policy "Users can insert their own profile"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = id);

-- Populate profiles automatically whenever a new auth.users row is created,
-- reading full_name/institution out of the signUp() metadata payload —
-- but ONLY for real researcher signups. Participant devices authenticate
-- anonymously (is_anonymous = true) against this same project to call
-- resolve_study_bootstrap(); skip those so they never get a profiles row.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if new.is_anonymous then
    return new;
  end if;

  insert into public.profiles (id, full_name, institution)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.raw_user_meta_data ->> 'institution'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
