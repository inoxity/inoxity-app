-- ================================================================
-- CONTROL BACKEND ONLY — apply only to the inoxity_backend project.
--
-- studies has never had a DELETE policy or grant — deleting a study was
-- never actually possible from the dashboard, despite
-- DeleteAccountControl's own copy ("delete those studies first") implying
-- it already was. This closes that gap.
--
-- Owner-only, not Admin — the same trust level as
-- transfer_study_ownership (008_study_collaborators.sql) and stricter
-- than canEdit (which includes Editor/Admin collaborators): deleting a
-- study is irreversible and removes it for the entire team, not just a
-- personal edit.
--
-- No cleanup needed beyond what already cascades: study_collaborators.
-- study_id is `on delete cascade` (008), and nothing else references
-- studies.id (study_backend_id/study_backends were dropped entirely in
-- 007_data_backend_in_json.sql — a study's own Data Backend project is
-- just a URL/key inside configuration_json, not a row anywhere in this
-- database). The precondition that a study be deactivated first lives in
-- deleteStudy() in inoxity-dashboard/src/lib/study-actions.ts, same
-- pattern as setStudyArchived().
-- ================================================================

create policy "Owner can delete their own studies"
  on public.studies
  for delete
  to authenticated
  using (
    (auth.jwt() ->> 'is_anonymous')::boolean is not true
    and auth.uid() = owner_id
  );

grant delete on public.studies to authenticated;
