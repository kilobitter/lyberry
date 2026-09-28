# MOVIES — Astra acceptance

Status: accepted for Android debug/source handoff, 2026-09-26.

## Delivered scope

Lyberry 0.5.0 adds UPCMDB DVD/Blu-ray barcode identification, explicit movie
title/year search, distinguishable edition candidates, and a securely stored
personal API key in Settings. Existing candidate selection and editable copy
flows preserve the original scanned barcode and personal-data semantics.

## Review and corrections

Astra reviewed the actual changes against `work/baselines/movies-pre-050`, then
the corrections against `work/baselines/movies-review1`, applying specification
and quality/security checks together. REVIEW-MOVIES.md records the findings.
All material findings are resolved: correct `/api/v1` endpoint base, generation
checks after queued admission and before credential use, strict checksum-validated
code equivalence, existing cover-URL policy, silent optional-key barcode fallback,
separate edition identities and labels, and stale/duplicate title-search guards.

A narrow follow-up within the correction/debugging phase fixed one stale test
expectation and the remaining equal-invalid-code shortcut, and added an explicit
queued title-search credential regression. This extra check was justified by the
concrete credential-use race and incomplete validation found in the actual patch.
No schema, dependency, library merge behavior or platform permissions changed.

## Verification

- 80 focused movie, UI/controller and routing tests passed.
- Full suite: **485 passed**, including all movie and existing render tests.
- Flutter analysis: no issues. Dart formatting: 147 files, zero changes.
- Five movie goldens and the affected games Settings golden were updated, then
  verified by the full suite. Astra inspected normal/narrow results and Settings.
- Historical evidence: 90 PNGs match the pre-movie baseline.
- A fresh Gradle build succeeded. APK verification caught stale generated Android
  version metadata (0.4.1+6); it was synced to pubspec and rebuilt successfully.
- Final APK: version 0.5.0+7, ZIP integrity passed, arm64-v8a / armeabi-v7a /
  x86_64 verified. Size 176255296 bytes. SHA-256:
  `52f986e09d8c760550a1ed723873b3b5e407fa802161dc993daa7d8002bdd01f`.
  Artifact: `deliverables/lyberry-0.5.0-debug.apk`. Curated source archive:
  `deliverables/lyberry-0.5.0-source.zip`, with adjacent manifest/checksums.

Logs and renders: `evidence/movies/`. Actual commands and exits are captured in
the correction command records. Root executed Flash's Flutter/Gradle commands
because granted cache permissions did not propagate to the existing child.
Flash implemented, debugged and wrote tests; Astra planned and reviewed.
The previously verified native DeepSeek V4.1 Flash route was reused; no paid
setup/auth probe or credential changes were performed.

## Verification limits

No authenticated UPCMDB request was made and live coverage for the sample EANs
is unknown. Public-demo denial was not treated as a no-match. Android emulator
5562 was offline, so install/launch and library-preservation smoke for this
release were unavailable; no device library was modified. iOS runtime remains
untested. Covers outside the existing allowlist are omitted without blocking
manual entry or saving. No commit, push, deployment or store release was made.
