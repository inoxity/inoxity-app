# Inoxity V2 backend topology

```text
Participant App
      |
      v
inoxity_backend
(Control Backend)
      |
      v
Study Backend
(one Supabase project per study)
      |
      v
Participant data services
(HealthKit / Survey / Media, when a study has media enabled)
```

The Control Backend is the `inoxity_backend` project. It owns study metadata, immutable configuration revisions, backend routing, and future researcher infrastructure. It resolves an exact study code and returns the public descriptor for that study’s Study Backend. Participant data never flows into `inoxity_backend`.

Each Study Backend is one independent Supabase project for exactly one study. It owns participant authentication, participant records (including self-reported wake/bed time), enrollment, withdrawals, durable survey opened/completed events, configured HealthKit samples (one table per data type — see `study_backend_template/README.md`), and — for studies with media enabled — uploaded media files (`media_uploads` table + `user-uploads` Storage bucket). Study Backends are isolated from one another.

The active deployment files are exclusively:

- `control_backend` for `inoxity_backend`.
- `study_backend_template` for each independent Study Backend.

Files under `archive` are historical references and are not deployment inputs.

Configure the iOS app with only `INOXITY_CONTROL_SUPABASE_URL`, `INOXITY_CONTROL_SUPABASE_ANON_KEY`, and `INOXITY_ENVIRONMENT` in an ignored local xcconfig. Study Backend descriptors are resolved dynamically. Never use V1, cross-apply migration directories, or store service-role keys, database passwords, or live project values in this repository.

Verification order:

1. Enable anonymous authentication independently in the Control Backend and every Study Backend.
2. Apply and verify `control_backend` (through `007_data_backend_in_json.sql`) only in `inoxity_backend`.
3. Apply and verify `study_backend_template` independently in each Study Backend.
4. Insert the matching immutable Study Backend identity (`study_backend_metadata`) in that Study Backend project.
5. Enter that same `backend_instance_id`, its project's public URL, and its public anonymous key into the dashboard's "Data Backend" wizard step and save the study — as of `007_data_backend_in_json.sql` these live inside `studies.configuration_json.dataBackend`, not a separate `study_backends` table/row.
6. Enroll fake participants and confirm no participant identifier appears in `inoxity_backend`.
7. Confirm SLEEP01 and ACTIVITY02 route to isolated Study Backends before production use.

## Approved Development setup order

1. Sign in to Supabase and verify `inoxity_backend` is V2, not V1.
2. Inspect schema drift; apply only `control_backend/migrations/001_control_schema.sql` and `002_control_rls_and_rpcs.sql` if needed.
3. Enable anonymous authentication in the Control Backend.
4. Create `inoxity_sleep01_dev`, enable anonymous authentication, apply `study_backend_template/migrations/001_study_data_schema.sql` through `006_healthkit_sample_rpc.sql` (through `008_media_upload_rpc.sql` if that study uses media), then always `009_withdrawal_deletion.sql`, `010_reenrollment_after_withdrawal.sql`, and `011_update_participant_identifier.sql`, insert its identity, and run all three Study Backend verification scripts.
5. Create and verify `inoxity_activity02_dev` independently using the same ordered template.
6. Insert only public Study Backend descriptors centrally, then insert validated Development configurations.
7. Configure the ignored local Control Backend credentials and test fake enrollment, withdrawal, and survey events.
8. Test HealthKit and (for media-enabled studies) media upload on a physical iPhone.

Archived SQL under `archive/phase3b_single_backend` is historical only and must never be applied or referenced by active setup procedures.

## Phase 3D Apple Health uploads

Apple Health research samples flow only to the participant's verified Study Backend. The Control Backend (`inoxity_backend`) stores configuration and routing metadata and never receives HealthKit samples. Apply Study Backend migrations `005_healthkit_samples.sql` and `006_healthkit_sample_rpc.sql` only after migrations 001–004.

The app uploads minimal normalized readable samples for the existing ten-type allowlist, each landing in its own dedicated table (`sleep_samples`, `heart_rate_samples`, etc. — see `study_backend_template/README.md`). Quantity units are `count`, `count/min`, `ms`, `kcal`, and `min`; workout duration is seconds. IDs are deterministic HealthKit-UUID namespaces, batches are capped at 250, and initial collection is bounded to 30 days without preceding enrollment or study dates. Candidate anchors promote only after all required IDs are acknowledged, making offline retry and relaunch idempotent.

“See My Data” remains an independent local Apple Health summary pipeline; summary cards are never uploaded. Phase 3D synchronizes readable HealthKit samples incrementally. Later deletion or correction events reported by Apple Health are not yet synchronized to the Study Backend, so it is not a perfect mirror of Apple Health.
