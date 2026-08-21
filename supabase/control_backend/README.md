# Control Backend

Apply these migrations only to a new Inoxity V2 `inoxity_backend` project. Enable anonymous authentication, apply `001` then `002`, run the control verification script, and add Development studies using a private local copy of the example seed.

The Control Backend stores only study metadata, immutable configuration JSON, public Study Backend descriptors, backend routing, and future researcher infrastructure. Participant data never flows into this project. It must not contain participant records, enrollments, withdrawals, HealthKit, surveys, media, or Storage objects.

The participant-facing role can execute only `resolve_study_bootstrap(text)`. It cannot list or modify studies or Study Backend descriptors. Run `tests/control_rls_verification.sql`; it uses fake rows inside a rolled-back transaction and fails loudly on unsafe privileges or prohibited application tables. Never place service-role credentials in descriptor rows.
