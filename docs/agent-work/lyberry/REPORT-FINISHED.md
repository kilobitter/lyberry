# REPORT-FINISHED — per-copy finished flag (0.6.0+8)

**Status: accepted for Android debug/source handoff, 2026-09-28.**

Flash completed implementation, tests, debugging and the README update. Astra
reviewed the source and renders, ran the supplied Flutter/Gradle commands with
its granted cache access, and finalized this report from the actual evidence.
The final docs-only worker request was interrupted after an extended wait;
Astra completed report integration. No implementation or verification remains
pending, and no worker is active.

Brief: BRIEF-FINISHED.md. Review: REVIEW-FINISHED.md.
Acceptance: ACCEPTANCE-FINISHED.md. Evidence: evidence/finished/.
Baseline: parent work/baselines/finished-pre-060 (553 curated files, 0.5.0+7),
with correction baseline finished-review1.

## 1. What changed

| Area | File | Change |
| --- | --- | --- |
| Eligibility | `lib/domain/media_type.dart` | `MediaType.isFinishable` — true only for book, DVD, Blu-ray |
| Model | `lib/domain/media_item.dart` | `isFinished` (default false) in the constructor, `toJson`, `fromJson` (absence → false for legacy payloads; a present value must be a boolean, so an explicit null is rejected), `copyWith`, equality and hashCode |
| Draft | `lib/state/item_draft.dart` | `isFinished` on the draft, carried by `fromItem`, false for `fromCandidate`/manual, written by `buildItem` |
| Storage schema | `lib/data/database.dart` | Schema 2; `is_finished INTEGER NOT NULL DEFAULT 0 CHECK (is_finished IN (0,1))`; transactional `onUpgrade` from 1 → 2; the current-version schema check now also requires the column; unknown upgrades and downgrades still refuse |
| Repository | `lib/data/sqlite_media_repository.dart` | Row mapping both ways; `createCopy` starts false |
| Backup | `lib/domain/library_snapshot.dart` | Export schema 2; import accepts 1 and 2; schema 2 items must state a boolean `isFinished`; schema 1 defaults false and honours an explicit value; present-but-wrong values are rejected in both |
| Editor | `lib/ui/screens/editor_screen.dart` | Labelled `Finished` checkbox (key `field-finished`) in the personal-data area, only for finishable media, disabled while saving |
| Detail | `lib/ui/screens/detail_screen.dart` | `Finished / Not finished` status row (key `detail-finished`, semantics label set) for finishable media; the add-copy message now mentions the flag |
| Test support | `test/support/test_support.dart`, `test/support/in_memory_repository.dart` | `sampleItem(isFinished:)`; the in-memory copy path resets the flag |
| Version | `pubspec.yaml`, `lib/ui/screens/settings_screen.dart`, `android/local.properties` | `0.6.0+8` (the generated Android version properties are synced so a direct Gradle build reports 0.6.0/code 8) |

Behavioural contract as implemented:

- The flag is per owned copy and personal: provider-prefilled and manual copies
  start false; "add another copy" resets it while the original keeps its value.
- Applicability is a UI concern. Storage keeps the boolean on every medium, the
  control only appears for book/DVD/Blu-ray, and a medium edit hides it without
  clearing it (switching back shows the stored value again).
- Editor changes only persist on Save; cancelling leaves storage untouched.
  Editing metadata (including applying a provider candidate) never touches the
  flag, and the existing controller flow updates the item timestamp as usual.
- Imports stay incoming-wins by item id in both directions, so a v2 file can set
  true → false and false → true, and a v1 file resets the flag to false.

## 2. Tests added (26 tests + 2 renders)

| File | Tests | Covers |
| --- | --- | --- |
| `test/domain/finished_flag_test.dart` | 8 | Eligibility per medium; default false; JSON both ways; legacy payload without the field; non-boolean rejected; copyWith/equality/hashCode; draft round-trip and provider/manual defaults; duplicate copy resets while the original stays finished |
| `test/domain/finished_backup_test.dart` | 6 | Schema 2 export and round-trip of both states; schema 2 requires the field; non-boolean **and explicit null** rejected in v1 and v2; v1 defaults false and honours an explicit true; imports replace the flag both directions; a `BackupService.chooseImport` file with one valid new copy plus one malformed existing copy is refused with the library unchanged (existing record identical, new copy absent, count unchanged) |
| `test/data/finished_sqlite_test.dart` | 6 | New library stores false and keeps true across close/reopen; a populated schema 1 file (real row + cover + photo + timestamps) opens, upgrades in place to schema 2 with every value and byte intact and `is_finished` present, then a later true is durable; a schema 99 file is refused with `StorageFailure` and left at version 99; a real export → merge round-trip flips the flag both directions and survives reopen; a duplicated finished copy starts false and stays false while the source stays true; a file that claims schema 2 but lacks the column is refused with its old row and version marker intact |
| `test/ui/finished_field_test.dart` | 6 | Save/reopen/detail flow; cancel keeps the stored value; only books and films show the control; hidden flag survives a CD switch and comes back checked; a provider candidate edit keeps the flag and saves; 320x568 at 1.6x text stays usable |
| `test/golden/render_evidence_test.dart` | +2 renders | `detail_finished_390x844.png`, `editor_finished_390x844.png` (the seeded Dune book is finished in those two only) |

Updated existing helper: `test/domain/snapshot_hardening_test.dart` now defaults
to schema 2 with an `isFinished` key, and its version-rejection list covers
`1.0`, `'1'`, `3` and `99` instead of treating `2` as future.

### 2a. Review corrections in this bundle (REVIEW-FINISHED.md)

| Finding | Fix |
| --- | --- |
| Explicit null accepted in `MediaItem.fromJson` | Presence is now checked with `json.containsKey`: absence stays the legacy default false, while a present value must be a boolean, so `isFinished: null` is rejected in v1 and v2 payloads |
| UI harness: home-grid tap after saving from detail (line 187) | The test now follows the real route (saving an edit opened from detail returns to detail) and re-opens the editor from `detail-edit`; every behaviour assertion is retained |
| UI harness: off-screen metadata title assertion (line 235) | The title `TextField` controller value is asserted after scrolling the field into view, and the final persisted title plus finished flag are still asserted after saving |
| Persistence evidence gaps | `chooseImport` no-write integration, real-SQLite export/merge both directions, duplicate-copy reset durability and the claimed-v2-missing-column refusal were all added (see §2) |

No UI layout was changed by these corrections, so the already-accepted render
goldens stay valid.

### 2b. Narrow test-debugging pass (full-suite triage)

Root's corrected full-suite run was 510 passed / 3 failed. Two were test-only
harness issues; the third was the Settings version-row golden. All are resolved
and the final full suite passes:

| Failure | Fix (test-only) |
| --- | --- |
| `test/ui/library_flow_test.dart` — `add another copy clears personal fields and keeps the original`: `enterText(field-review)` threw `StateError: No element` because the new Finished control moved the review field below the lazily built viewport | The test now calls its existing `reveal` helper for `field-review` (and for `field-finished`) before touching them. It also checks the Finished box on the original before saving, so the copy assertions now prove the duplicate resets the flag (`copy.isFinished == false`) while the original keeps it (`original.isFinished == true`) |
| `test/ui/p2_flow_test.dart` — `a malformed backup is reported without touching the library`: the fixture used `schemaVersion: 2`, which is now a supported version, but the test still expected `Unsupported schema version` | The fixture now sends an unreadable `schemaVersion: 99`; the rejection message assertion and the "library still has one item" assertion are unchanged |
| `movies_render_test.dart` — movie credentials Settings golden differs only by the 50px `Lyberry 0.6.0` version row | Root regenerated only this exact golden test and visually checked version 0.6.0; the full suite now passes |

No production code was changed in this pass.

## 3. Final validation

| Check | Actual result |
| --- | --- |
| Focused domain/backup/SQLite/UI tests | 63 passed — finished-focused.log |
| Full suite including all render tests | **513 passed** — finished-full-suite.log |
| Flutter analysis | No issues — finished-analyze.log |
| Dart formatting | 151 files, zero changes — finished-format-check.log |
| Fresh Android Gradle build | Successful in 22 seconds — finished-android-build.log |
| APK identity | 0.6.0, version code 8 |
| APK integrity / ABIs | ZIP passed; arm64-v8a, armeabi-v7a, x86_64 |
| Historical evidence | All 95 PNGs match the baseline |

Final commands and exits are in finished-final-commands.json and
finished-build-commands.json. Initial failure logs are retained as history;
the final results above supersede them. No further test reruns are requested.

Six new/changed renders are captured in evidence/finished/: finished editor and
detail, the existing editor/detail states, narrow editor, and movie Settings.
The only full-suite golden mismatch was the 50-pixel version-row change in
movie Settings, regenerated using that exact test and visually reviewed.
Historical images were not changed (render-preservation.json).

## 4. Artifacts

APK: deliverables/lyberry-0.6.0-debug.apk, **176257848 bytes**.
SHA-256: `0d2804a8a6844f6d42eff3c18c48a6929a9c2c664b66f0de9b29337f684d9668`.
Version, ABIs and integrity: apk-verification.txt and apk-badging.txt.
The source handoff is deliverables/lyberry-0.6.0-source.zip, with an adjacent
manifest and checksum, packaged by Astra after final documentation review.
Earlier release artifacts remain available.

## 5. Limits and scope

The only Android target, emulator-5562, was offline. Installation, launch and
on-device library-preservation checks were not performed for 0.6.0, and no user
device library was modified (device-smoke.txt). iOS runtime remains untested.
The migration uses populated fixtures matching the shipped v1 schema; it was
not tested against the user's actual database.

No live API or provider behavior was changed or tested. No credentials,
dependencies, platform permissions or game-filter behavior changed. No commit,
push, deployment, store release or paid model probe was performed. All product
code and test changes were implemented by Flash; Astra kept planning, review,
final integration and acceptance.
