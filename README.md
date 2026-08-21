# Inoxity Version 2

Development prototype of the participant-facing Inoxity iOS app, built with SwiftUI for iOS 17 and later. The app remains local-first; backend clients and deployment templates are present, but no production deployment is configured in this repository.

## Phase 1 — Configuration-driven foundation

Participants join with a study code that resolves to a bundled JSON configuration. The decoded configuration controls onboarding, participant identification, enabled tabs, study messaging, HealthKit data types, surveys, reminders, media settings, support information, FAQs, and completion behavior. Participant progress is versioned, persisted per study, restored across launches, and safely migrated or reset.

Bundled examples:

- `SLEEP01`: sleep-focused onboarding, Apple Health sleep data, surveys, sleep summary, and photo collection.
- `ACTIVITY02`: activity-focused onboarding, Apple Health activity data, surveys, video collection, and streak messaging.

## Phase 2 — Local participant features

- Configuration-driven Apple Health read authorization and limited local manual sync.
- Local notification permission, bounded scheduling, reconciliation, and study-scoped routing.
- Scheduled survey availability, in-app or external presentation, completion callbacks, and restoration.
- Local photo/video selection, validation, checksums, thumbnails, study-scoped storage, and a durable upload-ready queue.
- Shared Inoxity branding and app icon assets.

Media remains on-device and is not uploaded. Production backend deployment, researcher tools, background synchronization, and production media uploads are intentionally out of scope.

## Phase 3 — Isolated backend foundation

The app resolves configuration and routing through `inoxity_backend` (the Control Backend), then sends participant-facing operations directly to the exact isolated Study Backend for that study. Participant data never flows into the Control Backend. Phase 3C adds a versioned, durable, study-scoped survey-event queue and idempotent Study Backend RPC for opened and completed events. Opened acknowledgment is required before a matching completion is uploaded; exact routing metadata is retained for offline retries.

Phase 3D adds foreground synchronization of configured readable Apple Health samples directly to the participant’s verified Study Backend. The Control Backend receives no HealthKit data. Local “See My Data” summaries remain on-device, Inoxity never writes to Apple Health, and deleted or corrected Apple Health samples are not yet mirrored remotely. Media upload, background synchronization, live credentials, and production deployment remain out of scope.

All bundled URLs, contacts, surveys, and participant-facing privacy language are Development fixtures. Production copy requires research-team and study-governance review; see `supabase/DEVELOPMENT_FIXTURE_CHECKLIST.md`.

## Verification

The Xcode project includes an XCTest target covering configuration decoding and validation, persistence migration and isolation, HealthKit, notifications, surveys, media storage, queue behavior, restoration, and reset behavior.
