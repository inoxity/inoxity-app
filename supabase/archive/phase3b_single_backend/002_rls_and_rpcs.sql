-- ARCHIVED HISTORICAL SQL — DO NOT APPLY
-- Original Phase 3B single-backend RLS/RPC design, preserved for reference only.
alter table public.studies enable row level security;
alter table public.participants enable row level security;
alter table public.study_enrollments enable row level security;
alter table public.withdrawal_requests enable row level security;

create policy participant_owns_self on public.participants for select to authenticated
  using (auth_user_id = auth.uid());
create policy participant_owns_enrollment on public.study_enrollments for select to authenticated
  using (participant_id in (select id from public.participants where auth_user_id = auth.uid()));
create policy participant_owns_withdrawal on public.withdrawal_requests for select to authenticated
  using (participant_id in (select id from public.participants where auth_user_id = auth.uid()));

-- Historical RPC surface:
-- resolve_study_configuration
-- ensure_participant
-- register_study_enrollment
-- submit_withdrawal_request
--
-- The active V2 implementation intentionally splits these responsibilities between
-- the control backend and an independently verified Study Backend.
