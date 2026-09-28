# FINISHED — completion flag, Lyberry 0.6.0+8

User requests a field tracking whether books and movies/DVDs/Blu-rays have been
finished. Movies are already represented by dvd/bluray; add no media category.
Astra owns this design, acceptance/checkpoint/source packaging. Same native
Flash worker owns one bounded implementation, tests, debugging and report bundle.
Reuse the established route; no model probe or new agents.

Repo: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry` (no Git).
Baseline: parent `work/baselines/finished-pre-060`, 553 curated current files.
You are not alone in this workspace; preserve others' edits. Last accepted app:
0.5.0+7, 485 tests. Use existing dark Redline/Oxanium styles.

## Product and data contract

- Add `bool isFinished`, default false, to MediaItem and ItemDraft. Include it
  in item serialization, copyWith, equality/hash, repository row mappings, draft
  edit/save, and in-memory test repository. Provider-prefilled and manual new
  copies start false. Editing metadata must preserve this personal field.
- A shared media eligibility getter is true only for book/dvd/bluray. Show a
  labelled **Finished** checkbox in their editor's personal-data area and a
  **Finished / Not finished** status in the detail view. Accessible semantics,
  sensible spacing, normal disabled-while-saving behavior, no network request.
  Other media show neither. No home filter, progress/date/count, global title
  completion, or completion auto-inference from rating/review/metadata.
- Track per owned copy. Add another copy resets false along with other personal
  data and does not change the original. A medium edit may hide the control but
  must not discard its stored value; switching back restores the flag. Storage
  supports the bool on all records; applicability is a UI concern.
- Preserve changes until explicit Save, and cancellation must not persist them.
  Display stored state when reopening detail/editor; save updates timestamp via
  existing controller flow. Incoming-wins imports replace the flag in either
  direction using existing UUID identity semantics, never barcode matching.

## Compatibility decisions (Astra)

- SQLite schema **2**, additive `is_finished INTEGER NOT NULL DEFAULT 0
  CHECK (is_finished IN (0,1))`. New schema includes it; transactional upgrade
  1→2 only adds this column, preserving every old row, timestamp, index, asset and
  foreign-key behavior. Keep refusal of unknown upgrades/downgrades, never reset
  or recreate a library to make migration pass. Existing copies become false.
  Verify the expected new column when opening a claimed-v2 database.
- Backup schema **2** on export, importing both 1 and 2. Bumping the format keeps
  older apps from silently discarding the new personal field. v2 items require a
  boolean `isFinished`; v1 missing field defaults false. If present in either
  version, null/string/number is invalid, with atomic no-write failure. Domain
  fromJson can default an absent field for legacy items; SnapshotCodec owns the
  v2 presence requirement. Keep unknown version/type/bounds failures strict.
  Old imports still follow incoming-wins, so absent old flags become false.
- README documents schema migration, legacy imports and the new export version.
  No implementation/schema warnings in the normal app flow. No dependencies,
  permissions, provider/auth, Games filter, or unrelated feature changes.

## Ownership and dependency order (one phase)

1. Domain/serialization/draft and SQLite migration/row mapping, backup evolution.
2. Editor + detail field, test fakes/copy paths, relevant UI/state tests.
3. Verification/render fixes, release version 0.6.0+8 (pubspec/Settings/generated
   Android build version properties), README and REPORT-FINISHED.md.

Own relevant files under lib/domain, lib/data, lib/state/item_draft.dart,
editor/detail/Settings version, relevant test/support/fixtures/goldens, README,
pubspec and generated Android version values only. Root owns BRIEF/REVIEW/
ACCEPTANCE/CHECKPOINT and deliverable/source packaging. Report/evidence at
`docs/agent-work/lyberry/REPORT-FINISHED.md` and `evidence/finished/`.

## Required evidence and execution

Meaningful tests: false defaults; boolean true/false model/copy/equality/JSON;
legacy v1 backup with no field; v2 round-trip both states and missing/invalid
values atomically rejected; true→false and false→true incoming-wins merges;
real populated v1 SQLite fixture opened/upgraded/reopened, checking unchanged
metadata/assets/timestamps/count plus default false and durable subsequent true;
unsupported schema safely refused; new duplicate resets while original stays true;
editor save/reopen/cancel, metadata lookup preserves flag, eligible vs other media,
hidden/reappearing flag on medium changes; narrow320px/1.6x text safe.

Generate small clear renders for an eligible checked editor and detail state;
update only affected current goldens. Historical evidence PNGs under older phase
folders must remain unchanged. Relevant focused tests then final full suite,
analysis and format, fixing genuine failures inside this bundle.

Known environment: child's sandbox did not inherit root's granted Flutter/Gradle
cache writes. Do not repeat cache permission prompts or probes. Direct SDK binary
`/Users/ghijs/development/flutter/bin/cache/dart-sdk/bin/dart --suppress-analytics`
can run format/analyze. For Flutter tests/build, hand root exact commands and
expected golden targets after coherent implementation; root executes commands,
returns logs, and you debug any failure. This is a command-execution exception,
not a transfer of implementation/testing responsibility. Use `flutter
--suppress-analytics --no-version-check test --no-pub ...` (no-pub after command).
Root will build fresh Gradle after source acceptance with JBR21,
FLUTTER_SUPPRESS_ANALYTICS=true, --no-daemon --no-watch-fs and three ABIs; keep
generated Android version in sync (previous phase caught stale 0.4.1 metadata).
APK target deliverables/lyberry-0.6.0-debug.apk + checksum, source target0.6.0 ZIP.
Do not run live API requests or touch user keys/data. Emulator was offline;
root can attempt device smoke if available, without assuming it is online.

Finish ready_for_commands (accurate report with outstanding verification clearly
marked), then complete documentation with root-run evidence and ready_for_review.
No commit/push/deployment, deletion of existing library/deliverables, recursive
delegation, permission weakening, or unrelated refactor.
