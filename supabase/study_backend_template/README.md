# Study Backend template

Create one new Inoxity V2 Supabase Study Backend for exactly one study, enable anonymous authentication, and apply `001_study_data_schema.sql` through `011_update_participant_identifier.sql` in order (008 only if the study uses media — see below; 009, 010, and 011 apply regardless). Insert exactly one immutable identity row using a private copy of the example seed. Its backend UUID, stable study ID, code, and schema version must match the Control Backend descriptor and configuration.

The Study Backend owns participant authentication, participant records (including their self-reported wake/bed time), enrollment, withdrawals, durable survey opened/completed events, configured HealthKit samples, and — as of 007/008 — uploaded media files for that study. None of this ever flows through or into `inoxity_backend`. It must never receive participant data belonging to another study. Run `tests/study_rls_verification.sql`, `tests/survey_event_verification.sql`, and `tests/healthkit_sample_verification.sql` with fake users before adding its public URL and anonymous key to `inoxity_backend`.

Media selection, validation, thumbnails, and local storage are implemented in the app; remote upload (007's `media_uploads` table + `user-uploads` Storage bucket, 008's `submit_media_upload` RPC) is too, for studies that have media enabled. Withdraw-and-delete (009) deletes the participant's `media_uploads` row(s) along with the rest of their data — but not yet the underlying file objects in the `user-uploads` Storage bucket itself, since Storage object deletion isn't reachable from plain SQL (it needs a client-side or Edge Function call against the Storage API, not implemented yet).

Repeat with an independent Study Backend for every study design. Never apply this template to V1, the Control Backend, or another study's project.

## Phase 3D HealthKit setup

Apply `005_healthkit_samples.sql` and `006_healthkit_sample_rpc.sql` after migrations 001–004, then run `tests/healthkit_sample_verification.sql` using disposable fake participants. Both migrations are **STUDY DATA BACKEND ONLY** and must never be applied to `inoxity_backend`.

Each HealthKit data type gets its own dedicated table (`sleep_samples`, `heart_rate_samples`, `step_count_samples`, etc. — see 005) rather than one shared table, so a researcher can query/export a single data type directly. The `submit_healthkit_samples` RPC accepts at most 250 minimal normalized raw samples in one call (they may mix multiple data types), derives ownership from `auth.uid()`, validates Study Backend identity and enrollment, routes each sample to its matching table, and acknowledges identical retries idempotently. Direct authenticated insert, update, delete, and broad select access are revoked on every one of these tables. They contain no participant-facing identifier, device/source metadata, location, routes, survey data, or media data.

The app queries one foreground anchored page at a time, persists its queue before its candidate anchor, and promotes the anchor only after every required deterministic sample ID is acknowledged. State is isolated by study, enrollment, route, metric, and configuration revision. Withdraw-and-keep stops new collection while retaining queued records and marks the enrollment `withdrawn` server-side; withdraw-and-delete (009) clears that study's local queue and cursors, never touches Apple Health, and now also deletes the participant's rows from every one of these tables server-side (via cascading deletes off `study_enrollments`).

Supported identifiers span most of HealthKit's quantity, category, workout, and correlation catalog — activity/fitness, body measurements, vitals, hearing, environment, nutrition, heart-rhythm events, mindfulness, reproductive health, symptoms, and blood pressure, ~117 identifiers in total (see `HealthKitTypeRegistry.swift`'s `tableName` per identifier for the single source of truth on the app side, mirrored by `inoxity-dashboard/src/lib/study-schema.ts`'s `HEALTHKIT_IDENTIFIERS`/`generate-backend-sql.ts`'s `HEALTHKIT_TABLE_SPECS`, and by 005/006 here). Excluded, since they need Apple authorization beyond the standard HealthKit read permission already in place: Clinical Records and Documents. Also excluded, since they're structurally different from every other sample type here (waveform data, not a simple value): ECG and Audiogram. Which identifiers a given study actually collects is a research-team decision made in the dashboard's study wizard, not a software-level restriction — IRB/consent approval for a study's chosen types is the research team's responsibility. Every category type stores Apple's raw integer enum value in a generic `category_value` column, except `sleepAnalysis`, which keeps its original friendly six-value `state` text column. The participant-facing "See My Data" pipeline remains local and separate, and doesn't yet surface `bloodPressure` (a correlation, not a plain quantity — see 005's header comment).

Phase 3D synchronizes readable HealthKit samples incrementally. Later deletion or correction events reported by Apple Health are not yet synchronized to the Study Backend.

Manual verification requires anonymous authentication, migrations 001–006 (through 008 if the study uses media), matching backend metadata, a fake enrollment, and a physical iPhone with test HealthKit data. Verify rows appear only in the correct Study Backend, no rows appear in `inoxity_backend`, a second anonymous user cannot upload for the first, and retries remain idempotent. Simulator/static tests do not prove live backend or physical-device behavior.

## Sleep schedule sync

`participants.wake_time`/`bed_time` (001, `HH:mm` strings) are set via the `update_sleep_schedule` RPC (002) whenever the participant sets or edits their sleep schedule in the app (onboarding, or later from Settings) — this is a best-effort, fire-and-forget sync; the participant's device remains the source of truth for on-device notification scheduling regardless of whether a given sync call succeeds.

## Media uploads (007, 008 — only if the study has media enabled)

`media_uploads` (007) records metadata for files the app has already uploaded straight to the `user-uploads` Storage bucket; `submit_media_upload` (008) is the RPC that writes that metadata row after the fact. Storage access itself is governed by RLS policies on `storage.objects` (007), scoped to each participant's own `auth.uid()`-prefixed path — not by an RPC, since Supabase Storage doesn't support RPC-mediated writes. Skip applying 007/008 entirely for a study that doesn't use media.

## Withdrawal and data deletion (009)

Every table in this template has RLS enabled with all direct client access revoked — participants can only write through the RPCs above, which validate ownership, backend identity, and (where relevant) idempotency on every call; nothing here grants broad client-side insert/update access, by design.

`submit_withdrawal_request` (002, replaced by 009) is the one exception worth calling out: prior to 009 it only ever recorded the participant's withdrawal choice — it never actually deleted anything, regardless of which choice was submitted. As of 009, `withdrawal_choice = 'deleteExistingData'` genuinely deletes the participant's `survey_events`, all HealthKit sample rows, `media_uploads` rows, `study_enrollments` row, and `participants` row (cascading off HealthKit/media tables' existing `on delete cascade` foreign keys, plus an explicit delete for `survey_events`, which has none). The `withdrawal_requests` row itself survives as an anonymized audit record — 009 loosens its `participant_id`/`enrollment_id` foreign keys to `on delete set null` and sets `processed_at` — proof a deletion happened and when, with no way to trace it back to the deleted participant. `withdrawal_choice = 'keepExistingData'` now also transitions `study_enrollments.status` to `'withdrawn'`, which nothing did before 009 either.

**Known gap**: 009 deletes the `media_uploads` metadata rows but not the underlying file objects in the `user-uploads` Storage bucket — Postgres cascades can't reach Supabase Storage (a separate service, not a plain SQL delete target). `storage.objects` already has a participant-scoped DELETE policy (007) that a client could call directly, but nothing invokes it today. Closing this gap needs a client-side (or Edge Function) call against the Storage API, not a SQL change.

## Re-enrollment after withdrawal (010)

`register_study_enrollment` (002) made repeat calls idempotent by returning any existing `study_enrollments` row for that participant, regardless of status — which meant that once 009 started actually setting `status='withdrawn'` for `keepExistingData` withdrawals, a participant who tried to enroll again got that same withdrawn row handed back forever, and the client (`SupabaseRepositories.swift`'s `guard row.status == "active"`) rejected it as `BackendError.withdrawnEnrollment`, with no way back in. (`deleteExistingData` was never affected — it deletes the `participants` row outright, so a later attempt just inserts fresh.) As of 010, a withdrawn row is reactivated in place — `status` back to `'active'`, `enrollment_attempt_id`/`installation_id`/`configuration_schema_version`/`configuration_revision`/`enrolled_at` refreshed — rather than left inert or duplicated, so the participant's existing `survey_events`/HealthKit history (which `keepExistingData` promised to retain) stays attached to the same enrollment.

## Editing participant_identifier after enrollment (011)

`update_participant_identifier` lets the app's Settings screen correct a participant's own `study_enrollments.participant_identifier` (e.g. a SONA ID typo) after enrollment, without withdrawing and re-registering. It's restricted to the participant's own currently-`active` enrollment and does a basic non-empty/length sanity check server-side — the actual per-study format (length, allowed characters) is enforced client-side by `ParticipantIDValidator` against that study's `participantID` configuration before this RPC is ever called.

## Quick setup walkthrough (copy-paste steps)

One important thing to know up front: **`study_backend_metadata` is a singleton — one project can only ever represent one study.** Two studies can never share a Study Backend project, even temporarily for testing. Trying to point two studies at the same project causes a `backend_identity_mismatch` error the moment the second study tries to enroll.

1. **Create the Supabase project.** supabase.com/dashboard → New Project. Name it after the study (e.g. `inoxity-<studycode>-backend`), pick a region, set a DB password, wait ~2 min to provision.
2. **Enable anonymous sign-ins.** In the new project: Authentication → Providers (or Authentication → Settings) → turn on "Allow anonymous sign-ins." Participants authenticate anonymously — there's no participant-facing login.
3. **Apply the migrations, in order**, in the new project's SQL Editor: `001_study_data_schema.sql`, `002_study_data_rls_and_rpcs.sql`, `003_survey_events.sql`, `004_survey_event_rpc.sql`, `005_healthkit_samples.sql`, `006_healthkit_sample_rpc.sql`, and — only if this study has media enabled — `007_media_uploads.sql`, `008_media_upload_rpc.sql`, then always `009_withdrawal_deletion.sql`, `010_reenrollment_after_withdrawal.sql`, and `011_update_participant_identifier.sql`. Paste each file's full contents and run it before moving to the next. (If you used the dashboard's "Download setup SQL" button instead, it's already narrowed to exactly the HealthKit types and media setting this study needs, in one file — paste that whole file in one go instead of applying these individually. If your dashboard-generated file predates 009/010/011, apply those separately afterward.)
4. **Generate one UUID up front** (e.g. `uuidgen` in Terminal) — you'll use the *same* UUID in both steps 5 and 7 to link the two sides together.
5. **Seed this project's identity**, still in the new project's SQL Editor:
   ```sql
   insert into public.study_backend_metadata (
     singleton, backend_instance_id, stable_study_id, expected_study_code,
     supported_configuration_schema_version, is_active
   ) values (
     true,
     '<uuid from step 4>',
     '<the study's identity.id from its configuration_json, e.g. "real-test-1">',
     '<the study code, e.g. "TEST1" — must be uppercase>',
     5,  -- must match the study's configuration schemaVersion
     true
   );
   ```
6. **Get the new project's URL and anon key**: Settings → API in the new project.
7. **Enter it in the dashboard**, on the study's "Data Backend" wizard step: the *same* UUID from step 4 as the Backend ID, the project URL and anon key from step 6, and the environment. Save the study. As of `control_backend/migrations/007_data_backend_in_json.sql` this is stored inside `studies.configuration_json.dataBackend` — there is no separate `study_backends` table to insert into anymore, and no manual `update ... set study_backend_id` step.
8. **Test enrollment in the app.** If something goes wrong, Supabase's Postgres/Edge/Auth Logs (project dashboard → Logs) show the real error — the app's own error messages are sometimes generic. Edge Logs show HTTP status codes for each RPC call (e.g. a `409` means a unique-constraint conflict); Postgres Logs show the exact exception text for real database errors. Logs can take up to ~30–60 seconds to appear after the request — if you see nothing, wait and re-check before assuming something's broken.
