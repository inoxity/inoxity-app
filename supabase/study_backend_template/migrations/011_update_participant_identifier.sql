-- ================================================================
-- STUDY DATA BACKEND ONLY — apply to exactly one Study Backend, after 001-010.
--
-- Lets a participant correct their own study_enrollments.participant_identifier
-- (e.g. a SONA ID typo) from Settings after enrollment, without going through
-- withdrawal/re-enrollment. Mirrors update_sleep_schedule (002)'s shape: the
-- IN param is p_-prefixed for the same reason — participant_identifier is
-- also a column name on study_enrollments, and a bare reference anywhere
-- that table is in scope makes plpgsql treat it as ambiguous (42702).
--
-- Client-side format validation (ParticipantIDValidator, against this
-- study's configured label/min/max length/allowedPattern) already runs
-- before this RPC is called; the server has no access to that per-study
-- config to re-validate the exact pattern, so this only enforces a basic
-- non-empty/length sanity bound.
--
-- Restricted to the participant's currently *active* enrollment — there's
-- no legitimate reason to edit the identifier on a withdrawn enrollment from
-- Settings, and doing so would also bypass 010's reactivation path.
-- ================================================================

create or replace function public.update_participant_identifier(expected_backend_id text, expected_stable_study_id text,
 p_participant_identifier text)
returns table(enrollment_id uuid, participant_identifier text)
language plpgsql security definer set search_path = pg_catalog, public as $$ declare m public.study_backend_metadata%rowtype; p public.participants%rowtype; e public.study_enrollments%rowtype; begin
 if auth.uid() is null then raise exception 'unauthorized' using errcode='42501'; end if;
 select * into m from public.study_backend_metadata where singleton;
 if not found or not m.is_active then raise exception 'study_backend_inactive' using errcode='55000'; end if;
 if m.backend_instance_id <> expected_backend_id::uuid or m.stable_study_id <> expected_stable_study_id then raise exception 'backend_identity_mismatch'; end if;
 if length(trim(p_participant_identifier)) = 0 or length(p_participant_identifier) > 128 then raise exception 'invalid_participant_identifier' using errcode='22023'; end if;
 select * into p from public.participants where auth_user_id=auth.uid(); if not found then raise exception 'participant_missing'; end if;
 update public.study_enrollments set participant_identifier = p_participant_identifier
   where participant_id = p.id and status = 'active'
   returning * into e;
 if not found then raise exception 'enrollment_missing' using errcode='22023'; end if;
 return query select e.id, e.participant_identifier;
end $$;

revoke all on function public.update_participant_identifier(text,text,text) from public, anon;
grant execute on function public.update_participant_identifier(text,text,text) to authenticated;
