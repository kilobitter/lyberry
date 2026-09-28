# FINISHED — Astra acceptance

Status: accepted for Android debug/source handoff, 2026-09-28.

## Delivered scope

Lyberry 0.6.0+8 adds a personal Finished checkbox for each book, DVD and Blu-ray
copy, with Finished / Not finished displayed on its detail page. New and duplicate
copies start unfinished; edits and metadata lookup preserve the value. Changing
the medium hides the control where inapplicable without discarding its value.

SQLite schema 2 adds is_finished in place to existing libraries. Backups export
schema 2 and import schemas 1 and 2. A missing legacy flag defaults to false;
schema 2 requires a boolean. Present null and other wrong types are rejected.
Incoming-wins import updates the flag in either direction, per item ID.

## Review

Astra reviewed actual source and test changes against finished-pre-060 and the
correction baseline finished-review1, combining specification and data-integrity
checks. REVIEW-FINISHED.md records resolved findings: explicit-null validation,
UI test navigation/visibility, and meaningful backup/SQLite persistence tests.
A test-only follow-up fixed two stale full-suite fixtures; no further production
changes were required. Astra visually inspected the checked editor/detail views,
narrow layout and Settings version render. No provider, credential, dependency,
platform permission or game-filter behavior changed.

## Verification

- Focused persistence/domain/UI suite: 63 passed.
- Final full suite: **513 passed**, including all render tests.
- Flutter analysis: no issues. Dart formatting: 151 files, zero changes.
- SQLite tests cover populated v1 migration, preserved records and assets,
  reopen durability, duplicate reset, import updates in both directions and
  refusal of malformed/future database versions without replacing the file.
- Backup tests reject malformed inputs before writes and cover schemas 1 and 2.
- Six new/changed render images are captured under evidence/finished/.
  All 95 historical evidence PNGs match the pre-feature baseline.
- Fresh three-ABI Gradle build: successful in 22 seconds.
- APK version 0.6.0+8; ZIP integrity passed; arm64-v8a, armeabi-v7a and x86_64
  verified. Size 176257848 bytes. SHA-256:
  `0d2804a8a6844f6d42eff3c18c48a6929a9c2c664b66f0de9b29337f684d9668`.
  APK: deliverables/lyberry-0.6.0-debug.apk, with adjacent checksum.
  Source handoff: deliverables/lyberry-0.6.0-source.zip, manifest and checksum.

Commands, exits, logs, renders and APK verification: evidence/finished/.
Flash implemented/debugged/tested; Astra planned, reviewed and integrated.
Root executed Flash's Flutter/Gradle commands because the existing child did not
inherit toolchain-cache grants. The existing verified native V4.1 Flash route
was reused without paid probes or credential changes.

## Verification limits

The v1 migration fixture represents the shipped schema; no real user database
was opened. The only Android target, emulator-5562, is offline, so this release
has no install/launch or device-library-preservation smoke result. Device data
was not changed. iOS runtime remains untested. No live API calls, commit, push,
deployment or store release were performed.
