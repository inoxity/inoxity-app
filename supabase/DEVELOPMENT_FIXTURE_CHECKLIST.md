# Development fixture inventory

The bundled SLEEP01 and ACTIVITY02 configurations are Development fixtures, not approved production study content. Do not replace these values with guesses. Before a real Fall study, Rachael or the designated research-team owner must supply and approve every item below.

## Current placeholders

| Study | Fixture values requiring replacement |
|---|---|
| SLEEP01 | `example.edu` morning-survey URL, `sleepstudy@example.edu`, support website, prototype onboarding/privacy wording, prototype FAQ answers |
| ACTIVITY02 | `example.org` energy-survey and completion URLs, `activitystudy@example.org`, `+1-555-0102`, support website, prototype HealthKit/media FAQ wording |
| Template | `example.edu` survey/support values, example survey definition, prototype privacy and media wording |

No separate callback URL is configured: completion callbacks currently return through the app’s configured callback contract. The real survey provider must supply and validate its matching callback behavior.

## Required for each real Fall study

- Final stable study ID and normalized study code
- Research-team-approved display name, welcome text, onboarding, FAQs, and completion text
- Participant identifier label, format, validation pattern, and fake Development test values
- Study dates, enrollment dates, and timezone
- Approved HealthKit identifiers and participant-facing rationale
- Approved explanation of Study Backend uploads, local summaries, Apple Health source-of-truth behavior, and deletion limitations
- Survey provider URL, presentation mode, schedule, availability window, and callback contract
- Reminder text and schedule
- Support name, monitored email, phone, and website
- Media categories and limits, while clearly retaining local-only status until a separate backend phase
- Control configuration revision and Study Backend descriptor revision
- Confirmation that production copy received the required research-team, governance, privacy, and IRB review

Never store service-role keys, secret keys, database passwords, JWT secrets, real participant identifiers, or live credentials in this repository.
