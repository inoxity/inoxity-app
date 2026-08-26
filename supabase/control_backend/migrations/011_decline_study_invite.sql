-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- The only decline path for a study invite — accept_study_invite()
-- (008_study_collaborators.sql) was the only existing path, and it only
-- ever sets accepted_at. This mirrors its exact guard structure (same
-- three error codes, same "must be signed in as the invited email"
-- consent check) but deletes the pending row instead of accepting it —
-- declining means "not interested," not "leave a rejected record behind."
-- A fresh invite to the same email is a plain insert afterward, same as
-- after removeCollaborator's delete.
-- ================================================================
create or replace function public.decline_study_invite(p_token text)
returns void
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

  delete from public.study_collaborators where id = inv.id;
end;
$$;

revoke all on function public.decline_study_invite(text) from public;
-- Not granted to anon, unlike get_invite_preview — declining requires
-- actually being signed in as the invited person, same as accepting.
grant execute on function public.decline_study_invite(text) to authenticated;
