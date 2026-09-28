# FINISHED — Astra review record

2026-09-28. Actual source patch reviewed against finished-pre-060 with both
specification and correctness/data-preservation lenses. Correction baseline:
parent work/baselines/finished-review1. Domain/draft/UI/SQL migration wiring is
appropriately scoped; normal/narrow renders and eligible status look correct.
Root-run focused tests: 56 passed, 4 failed. Seven render tests passed (including
new finished editor/detail); those current goldens are already regenerated.

## Consolidated corrections

1. **P2 — Explicit null accepted in backup personal field.**
   `lib/domain/media_item.dart` checks only non-null non-bools; `isFinished:null`
   becomes false, even in a v2 backup. This violates strict field validation and
   could overwrite an existing finished value on import. Differentiate absence
   (legacy default false) from a present value (must be bool, including rejecting
   null). Existing two tests already fail correctly; keep them and correct code.

2. **UI regression harness failures.** `test/ui/finished_field_test.dart:187`
   tries to tap a home-grid item while editing has returned to its detail route.
   Fix the navigation expectation to follow the actual route. At line235 the
   metadata title assertion is made while its field is offscreen; verify the
   actual TextField/controller value after scrolling as needed and keep the final
   persisted title + finished assertions. Do not weaken the behaviors covered.
   Inspect the log if there is an additional actual UI issue.

3. **Persistence evidence gaps.** The malformed-backup test decodes directly
   and then inspects a repository that no tested operation used. Exercise
   `BackupService.chooseImport` via FakeSnapshotIo with a valid new item plus a
   malformed existing item; verify rejection and unchanged records/count. Add a
   focused real-SQLite round-trip covering export/import flag replacement in both
   directions and duplicate-copy reset while the source remains finished. Also
   cover refusal of a claimed-v2 database lacking is_finished, checking its old
   data remains intact. These are targeted checks for new persistence boundaries.

No UI redesign or further scope is requested. Root reviewed the actual new
editor/detail screenshots and accepts their layout. No full suite or build has
run yet; current logs are evidence/finished/finished-focused.log and
finished-goldens-update.log. Root will rerun the corrected focused suite, analysis,
format and full suite, update only any expected failing current goldens, then
build and verify the 0.6.0+8 APK. Historical evidence remains separately preserved.

Flash owns fixes/tests and report; root owns command execution due the known
child cache-permission limitation and final acceptance/packaging. No new permission
prompts, live APIs, keys or user-device database modifications.

## Resolution — 2026-09-28

The consolidated corrections were reviewed in the actual source and accepted:
present null is rejected, UI navigation assertions follow the real routes, and
backup/SQLite tests now exercise persistence and rejection boundaries. The
corrected focused suite passed all 63 tests; analysis and formatting were clean.

The first full run reached 510 passed / 3 failed. Two legacy test assumptions
were fixed in a scoped test-only follow-up: reveal the lazily built review field
before entering text (the duplicate-copy test also now checks the finished reset),
and use schema 99 for the unsupported-version fixture. Root reviewed that diff;
no product code changed in this follow-up. The only golden mismatch was the
movie Settings version row (50 pixels), regenerated using the exact test name
and visually inspected with version 0.6.0. Final validation and artifact outcomes
are recorded in ACCEPTANCE-FINISHED.md.
