-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- Adds study collaborators (Admin/Editor/Viewer roles alongside the
-- existing implicit Owner via studies.owner_id — see
-- 004_dashboard_ownership.sql). A row here is either:
--   * a PENDING invite: user_id is null, accepted_at is null — someone
--     was invited by email but hasn't (yet) linked an account to it.
--   * an ACCEPTED collaborator: user_id and accepted_at are both set.
-- Nothing in this table ever represents the Owner — ownership stays a
-- single non-null studies.owner_id column. Unlike the original design
-- draft, ownership transfer here is Owner-initiated only (see
-- transfer_study_ownership below) — an Admin can manage the roster but
-- can never take or reassign ownership itself.
--
-- Also adds get_study_support_contact(), used by the dashboard's
-- unauthenticated /api/contact route (see src/app/api/contact/route.ts)
-- to resolve "who do we email" from just a study code, without exposing
-- the rest of configuration_json (which can hold dataBackend credentials).
-- ================================================================

create table public.study_collaborators (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null references public.studies(id) on delete cascade,

  -- Null until the invited email is linked to a real account — either
  -- pre-linked at invite time (find_profile_id_by_email, below) or later
  -- via accept_study_invite(). on delete cascade (not restrict, unlike
  -- studies.owner_id): losing collaborator access when someone deletes
  -- their account isn't the same load-bearing event as losing a study's
  -- only owner.
  user_id uuid references public.profiles(id) on delete cascade,

  -- Always set, even after accepted_at is populated, so re-inviting the
  -- same email after removal is a plain insert and audit history reads
  -- cleanly. Normalized the same way study_code is (see
  -- 001_control_schema.sql) — normalization happens in application code
  -- before insert, this just enforces the invariant server-side too.
  invited_email text not null check (invited_email = lower(trim(invited_email))),
  check (invited_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),

  role text not null check (role in ('admin', 'editor', 'viewer')),

  invited_by uuid references public.profiles(id) on delete set null,
  invite_token text not null default encode(gen_random_bytes(32), 'hex'),

  invited_at timestamptz not null default now(),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- One row per (study, invited email) — re-inviting after removal is a
  -- fresh insert (the old row is gone), not an upsert.
  constraint study_collaborators_study_email_unique unique (study_id, invited_email),
  constraint study_collaborators_invite_token_unique unique (invite_token),
  -- An accepted row must have a user_id; a user_id without accepted_at is
  -- allowed (pre-linked-but-not-yet-accepted — see find_profile_id_by_email).
  constraint study_collaborators_accepted_needs_user check (accepted_at is null or user_id is not null)
);

comment on table public.study_collaborators is
  'Per-study Admin/Editor/Viewer collaborators. Owner is never a row here — it stays studies.owner_id. Pending invite = user_id/accepted_at both null.';

create index study_collaborators_study_id_idx on public.study_collaborators (study_id);
create index study_collaborators_user_id_idx on public.study_collaborators (user_id) where user_id is not null;
create index study_collaborators_invited_email_idx on public.study_collaborators (invited_email);

alter table public.study_collaborators enable row level security;
revoke all on public.study_collaborators from anon, authenticated;

-- ----------------------------------------------------------------
-- has_study_role: the recursion-breaking helper. security definer,
-- owned by the migration role (same role that owns studies/
-- study_collaborators) — table owners bypass their own tables' RLS, so
-- the two queries below never re-trigger studies'/study_collaborators'
-- own policies, which is what lets those policies safely call this
-- function without a studies -> study_collaborators -> studies cycle.
-- IMPORTANT: this only holds as long as this function's owner stays the
-- same role that owns those two tables — never `alter function ... owner
-- to` a different role, and never recreate it as a different role (e.g.
-- via a Supabase Studio GUI edit instead of a migration).
-- ----------------------------------------------------------------
create or replace function public.has_study_role(p_study_id uuid, p_min_role text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select
    exists (
      select 1 from public.studies s
      where s.id = p_study_id and s.owner_id = auth.uid()
    )
    or exists (
      select 1 from public.study_collaborators c
      where c.study_id = p_study_id
        and c.user_id = auth.uid()
        and c.accepted_at is not null
        and (
          p_min_role = 'viewer'
          or (p_min_role = 'editor' and c.role in ('editor', 'admin'))
          or (p_min_role = 'admin' and c.role = 'admin')
        )
    );
$$;

revoke all on function public.has_study_role(uuid, text) from public;
grant execute on function public.has_study_role(uuid, text) to authenticated;

-- ----------------------------------------------------------------
-- find_profile_id_by_email: narrow email -> profile id lookup. Defined
-- here (before the study_collaborators RLS policies below) because the
-- insert policy calls it. profiles has no email column (see
-- 003_researcher_profiles.sql) and its RLS restricts every user to their
-- own row, so this is the only way the dashboard can find out "does an
-- Inoxity account already exist for this email" without a service_role
-- key. Returns ONLY a uuid or null. security definer so it can read
-- auth.users (only the migration role has that grant in Supabase; this
-- mirrors handle_new_user()'s trigger on auth.users in
-- 003_researcher_profiles.sql, which already establishes that this role
-- has that access).
--
-- RISK — email enumeration: any authenticated user can call this with an
-- arbitrary email and learn whether an Inoxity account exists for it.
-- Accepted as low-severity (it returns a bare id, nothing else about the
-- account) — but never expose this through any UI beyond the invite flow.
-- ----------------------------------------------------------------
create or replace function public.find_profile_id_by_email(p_email text)
returns uuid
language sql
security definer
set search_path = auth, public
stable
as $$
  select p.id
  from public.profiles p
  join auth.users u on u.id = p.id
  where lower(u.email) = lower(trim(p_email))
  limit 1;
$$;

revoke all on function public.find_profile_id_by_email(text) from public;
grant execute on function public.find_profile_id_by_email(text) to authenticated;

-- ----------------------------------------------------------------
-- study_collaborators RLS
--
-- SELECT: three separate (OR'd) policies —
--   1. Owner/Admin can see the full roster for that study.
--   2. Any accepted collaborator can see their own row (any role).
--   3. A logged-in user can see their own PENDING invite by email match
--      (via the JWT's email claim, not a table read of auth.users — the
--      `authenticated` role has no direct SELECT grant on auth.users, so
--      a plain RLS policy can't subquery it; auth.jwt()->>'email' reads
--      the email claim already embedded in the caller's own JWT instead,
--      matching the existing auth.jwt()->>'is_anonymous' convention in
--      005_dashboard_rls_and_grants.sql) — this is what powers a "you
--      have a pending invite" banner on dashboard load.
-- INSERT/UPDATE/DELETE: Owner/Admin only.
-- ----------------------------------------------------------------
create policy "Owner or admin can view a study's collaborators"
  on public.study_collaborators
  for select
  to authenticated
  using (public.has_study_role(study_id, 'admin'));

create policy "Collaborators can view their own row"
  on public.study_collaborators
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy "Users can view their own pending invites by email"
  on public.study_collaborators
  for select
  to authenticated
  using (
    accepted_at is null
    and invited_email = lower(coalesce(auth.jwt() ->> 'email', '__no_match__'))
  );

create policy "Owner or admin can invite collaborators"
  on public.study_collaborators
  for insert
  to authenticated
  with check (
    public.has_study_role(study_id, 'admin')
    -- If an invite is pre-linked to an existing account (user_id set), it
    -- must actually be that account's profile id — prevents an admin from
    -- fabricating a user_id that doesn't match invited_email.
    and (user_id is null or user_id = public.find_profile_id_by_email(invited_email))
  );

create policy "Owner or admin can change a collaborator's role"
  on public.study_collaborators
  for update
  to authenticated
  using (public.has_study_role(study_id, 'admin'))
  with check (public.has_study_role(study_id, 'admin'));

create policy "Owner or admin can remove a collaborator"
  on public.study_collaborators
  for delete
  to authenticated
  using (public.has_study_role(study_id, 'admin'));

-- Lets any accepted collaborator remove themselves ("leave this study")
-- even if they're not an admin — cheap, low-risk, avoids someone being
-- stuck on a team forever with no admin willing to remove them.
create policy "Collaborators can remove themselves"
  on public.study_collaborators
  for delete
  to authenticated
  using (auth.uid() = user_id);

-- Column-level grants matter here for the same reason they do on
-- `studies` below: RLS with_check alone can't stop an admin's UPDATE
-- payload from also touching accepted_at/invite_token/invited_email,
-- which must only ever change via the security definer RPCs below
-- (accept_study_invite, transfer_study_ownership).
grant select on public.study_collaborators to authenticated;
grant insert (study_id, invited_email, role, invited_by, user_id) on public.study_collaborators to authenticated;
grant update (role, updated_at) on public.study_collaborators to authenticated;
grant delete on public.study_collaborators to authenticated;

-- ----------------------------------------------------------------
-- get_invite_preview: lets someone WITHOUT an Inoxity account yet preview
-- an invite by token before signing in, so /invite/[token] can say
-- "Study X invites you as Editor" before asking them to log in or sign
-- up. Granted to `anon` (not just `authenticated`) because a logged-out
-- dashboard visitor has no Supabase session at all — the dashboard has no
-- anonymous-sign-in flow the way the iOS app does, so that request really
-- is the plain `anon` Postgres role. The token itself is the credential
-- (64 random hex chars via pgcrypto's gen_random_bytes) — knowing it is
-- equivalent to having received the email — so exposing this to `anon` is
-- safe. Returns only display-safe fields — never configuration_json,
-- never anything from studies.dataBackend.
-- ----------------------------------------------------------------
create or replace function public.get_invite_preview(p_token text)
returns table (
  study_id uuid,
  study_display_name text,
  role text,
  invited_email text,
  invited_by_name text,
  already_accepted boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select
    c.study_id,
    coalesce(s.configuration_json -> 'identity' ->> 'displayName', s.stable_study_id),
    c.role,
    c.invited_email,
    p.full_name,
    c.accepted_at is not null
  from public.study_collaborators c
  join public.studies s on s.id = c.study_id
  left join public.profiles p on p.id = c.invited_by
  where c.invite_token = p_token;
$$;

revoke all on function public.get_invite_preview(text) from public;
grant execute on function public.get_invite_preview(text) to anon, authenticated;

-- ----------------------------------------------------------------
-- accept_study_invite: the ONLY path that ever sets accepted_at. Used by
-- BOTH "click the emailed link and I already have an account" and "I
-- signed up separately, later accept from a dashboard banner" — not a
-- handle_new_user() trigger extension, since that only fires at signup
-- and would miss anyone invited after already having an account (the
-- common case). Requires the caller to be logged in with the exact
-- invited email (case-insensitive, via the JWT email claim) — that's the
-- actual consent gesture, not just knowledge of the token.
-- ----------------------------------------------------------------
create or replace function public.accept_study_invite(p_token text)
returns uuid -- study_id, so the caller can redirect to it
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.study_collaborators%rowtype;
  caller_email text := lower(auth.jwt() ->> 'email');
begin
  if auth.uid() is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select * into inv
  from public.study_collaborators
  where invite_token = p_token
  for update;

  if not found then
    raise exception 'invite_not_found';
  end if;

  if inv.accepted_at is not null then
    raise exception 'invite_already_accepted';
  end if;

  if caller_email is null or caller_email <> inv.invited_email then
    raise exception 'invite_email_mismatch';
  end if;

  update public.study_collaborators
  set user_id = auth.uid(), accepted_at = now(), updated_at = now()
  where id = inv.id;

  return inv.study_id;
end;
$$;

revoke all on function public.accept_study_invite(text) from public;
grant execute on function public.accept_study_invite(text) to authenticated;

-- ----------------------------------------------------------------
-- get_study_team: read-optimized team roster (Owner + all collaborators,
-- joined to profiles for display names) for anyone with at least Viewer
-- access. Deliberately more permissive for READ than study_collaborators'
-- own SELECT policies (Owner/Admin + "your own row" only) — seeing your
-- teammates' names is benign, and this keeps the raw table's RLS tight
-- while still surfacing profiles.full_name across a shared study WITHOUT
-- broadening profiles' own RLS (which stays exactly as-is, scoped to
-- auth.uid() = id). security definer specifically so it can read every
-- joined profiles row, not just the caller's own.
-- ----------------------------------------------------------------
create or replace function public.get_study_team(p_study_id uuid)
returns table (
  collaborator_id uuid,
  user_id uuid,
  full_name text,
  institution text,
  invited_email text,
  role text,
  invited_at timestamptz,
  accepted_at timestamptz,
  is_owner boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.has_study_role(p_study_id, 'viewer') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
    select
      null::uuid as collaborator_id, s.owner_id as user_id, p.full_name, p.institution,
      null::text as invited_email, 'owner'::text as role,
      null::timestamptz as invited_at, null::timestamptz as accepted_at, true as is_owner
    from public.studies s
    join public.profiles p on p.id = s.owner_id
    where s.id = p_study_id
  union all
    select c.id, c.user_id, p.full_name, p.institution, c.invited_email,
           c.role, c.invited_at, c.accepted_at, false
    from public.study_collaborators c
    left join public.profiles p on p.id = c.user_id
    where c.study_id = p_study_id
    order by is_owner desc, accepted_at nulls last;
end;
$$;

revoke all on function public.get_study_team(uuid) from public;
grant execute on function public.get_study_team(uuid) to authenticated;

-- ----------------------------------------------------------------
-- transfer_study_ownership: Owner-initiated only — deliberately NOT
-- callable by an Admin collaborator, even though Admins can otherwise
-- manage the roster (invite/remove/change roles). Reassigning ownership
-- away from the Owner without their consent was flagged as a real risk
-- in review and rejected; only the current Owner can give ownership away.
-- ----------------------------------------------------------------
create or replace function public.transfer_study_ownership(p_study_id uuid, p_new_owner_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_owner uuid;
  old_owner_email text;
begin
  if auth.uid() is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select owner_id into current_owner from public.studies where id = p_study_id for update;
  if current_owner is null then
    raise exception 'study_not_found';
  end if;

  if auth.uid() <> current_owner then
    raise exception 'only_the_owner_can_transfer_ownership' using errcode = '42501';
  end if;

  if p_new_owner_id = current_owner then
    raise exception 'already_owner';
  end if;

  if not exists (
    select 1 from public.study_collaborators
    where study_id = p_study_id
      and user_id = p_new_owner_id
      and accepted_at is not null
      and role in ('admin', 'editor')
  ) then
    raise exception 'new_owner_must_be_existing_admin_or_editor';
  end if;

  select u.email into old_owner_email from auth.users u where u.id = current_owner;

  update public.studies set owner_id = p_new_owner_id, updated_at = now() where id = p_study_id;

  -- New owner no longer needs a collaborator row — ownership is implicit.
  delete from public.study_collaborators
  where study_id = p_study_id and user_id = p_new_owner_id;

  -- Old owner becomes an admin collaborator so they keep access instead of
  -- being silently locked out of a study they used to own.
  insert into public.study_collaborators (study_id, user_id, invited_email, role, invited_by, accepted_at)
  values (p_study_id, current_owner, lower(old_owner_email), 'admin', auth.uid(), now())
  on conflict (study_id, invited_email)
  do update set user_id = excluded.user_id, role = 'admin', accepted_at = now(), updated_at = now();
end;
$$;

revoke all on function public.transfer_study_ownership(uuid, uuid) from public;
grant execute on function public.transfer_study_ownership(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------
-- get_study_support_contact: used by the dashboard's unauthenticated
-- /api/contact route (called by the iOS app, not a signed-in researcher)
-- to resolve who to email for a given study code, without exposing the
-- rest of configuration_json (which can hold dataBackend credentials).
-- Granted to `anon` because that Next.js route talks to Supabase with
-- just the anon key and no user session.
-- ----------------------------------------------------------------
create or replace function public.get_study_support_contact(requested_code text)
returns table (support_name text, support_email text)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  normalized text := upper(trim(requested_code));
  study_row public.studies%rowtype;
begin
  select * into study_row from public.studies s where s.study_code = normalized;
  if not found or not study_row.is_active then
    raise exception 'study_not_found';
  end if;
  return query select
    study_row.configuration_json -> 'support' ->> 'name',
    study_row.configuration_json -> 'support' ->> 'email';
end;
$$;

revoke all on function public.get_study_support_contact(text) from public;
grant execute on function public.get_study_support_contact(text) to anon, authenticated;

-- ----------------------------------------------------------------
-- studies: broaden SELECT/UPDATE to admin/editor/viewer collaborators.
-- Recreated (not altered) since Postgres has no "alter policy add to
-- using clause" — drop + recreate under the same semantics as
-- 005_dashboard_rls_and_grants.sql, just OR'd with has_study_role().
-- INSERT stays owner-only and untouched: collaborators are added to
-- EXISTING studies, never granted the ability to create new ones.
-- ----------------------------------------------------------------
drop policy "Researchers can view their own studies" on public.studies;
create policy "Researchers and collaborators can view studies"
  on public.studies
  for select
  to authenticated
  using (
    (auth.jwt() ->> 'is_anonymous')::boolean is not true
    and (auth.uid() = owner_id or public.has_study_role(id, 'viewer'))
  );

drop policy "Researchers can update their own studies" on public.studies;
create policy "Owner or editor+ collaborators can update studies"
  on public.studies
  for update
  to authenticated
  using (
    (auth.jwt() ->> 'is_anonymous')::boolean is not true
    and (auth.uid() = owner_id or public.has_study_role(id, 'editor'))
  )
  with check (
    (auth.jwt() ->> 'is_anonymous')::boolean is not true
    and (auth.uid() = owner_id or public.has_study_role(id, 'editor'))
  );

-- Column-level UPDATE grant — closes a real privilege-escalation gap:
-- without this, the RLS with_check above would let any Editor issue
-- `PATCH studies?id=eq.<x> {"owner_id": "<their-own-uid>"}` and hijack
-- ownership, because with_check only re-validates the NEW row against the
-- same boolean — and if they set owner_id to themselves,
-- "auth.uid() = owner_id" trivially becomes true for the new row too.
-- Column grants are checked independently of RLS and can't be satisfied
-- by any row content, so this closes the hole regardless of what the RLS
-- expression says. owner_id is deliberately NOT in this list — it may
-- only change via transfer_study_ownership() above.
revoke update on public.studies from authenticated;
grant update (
  stable_study_id, study_code, configuration_schema_version, configuration_revision,
  configuration_json, is_active, enrollment_opens_at, enrollment_closes_at, updated_at
) on public.studies to authenticated;
