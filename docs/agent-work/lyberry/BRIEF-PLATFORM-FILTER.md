# Games platform filter — Astra brief (2026-09-25)

User: when Games is selected on the home page, show a platform dropdown whose
options exist on game entries in the library. Implement this bounded enhancement
as0.4.1+6 and provide a tested Android APK. User reports game lookup works well;
leave metadata/auth/network/backup/database schemas untouched.

Repo: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
No Git. Baseline: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/platform-filter-pre-041
(465curatedfiles+BASELINE.json). Existing verified Astra root/Flash route reused.
You are not alone; preserve others' work and prior versioned artifacts. Same
astra_flash_builder worker, no further delegation or orchestration skill load.

## Contract and architecture
- Home shows a compact, accessible dropdown labelled Platform directly below
  MediumTabs only when mediumFilter == MediaType.game. Default 'All platforms'.
  Use the established dark/red theme and full usable width. Long names and320px
  width/1.6text scaling must not overflow. If no named platforms exist, keep the
  All platforms control disabled; games with no platform remain visible in All.
- Options derive from ALL local game entries, independent of search query and
  current platform selection; never show platforms found only on non-games.
  Skip blank/whitespace-only names. Deduplicate using trimmed/collapsed whitespace
  and case-insensitive comparison, but retain a readable stored spelling. Sort
  alphabetically case-insensitively. Do not invent aliases (PS4 vs PlayStation4).
- Selecting one platform filters the game grid/count by that normalized platform
  AND the existing text search. All platforms removes only the platform predicate.
  No external requests and no persistent changes to item.platform values.
- Store transient filter state in LibraryController alongside medium/search.
  Expose platformFilter (null meansAll), availableGamePlatforms, and async
  setPlatformFilter. Keep existing repository interface; its listItems supports
  medium/query. A second unfiltered games-only list read during Games reload is
  adequate for deriving options; filter returned search matches locally. Avoid
  a new SQL schema/query-interface migration or a broad state rewrite.
- Reset platform selection when leaving Games and on clearFilters. On refresh
  after create/update/delete/import, recalculate options; if the selected platform
  has no remaining entries, fall back toAll in that same reload and show all game
  search results. No dropdown missing-value assertion or stale filtered grid.
  Keep all medium/text/platform reads and assignments consistent under existing
  _loadToken guard. Capture requested filter values for an async reload; stale
  completions must not overwrite the current selection/options/results.
- Existing totalCount stays the whole-library count; results count reflects all
  active predicates. Keep sorting/newest-first and all other media unchanged.

## Scope / ownership / verification
Own lib/state/library_controller.dart, lib/ui/screens/home_screen.dart, optionally
a small UI dropdown helper; necessary version label in settings_screen.dart and
pubspec.yaml; focused tests/render evidence; README release note; unique
REPORT-PLATFORM-FILTER.md and evidence/platform-filter/. Root owns brief,
ACCEPTANCE-PLATFORM-FILTER.md, CHECKPOINT.md, source packaging. Do not modify
unrelated lookup/auth/data code. No dependencies expected.

Use meaningful focused tests: game-only options (dedupe/blank/non-game exclusion),
combined search/platform +All and medium reset, live option changes including
deleting/editing the final entry on a selected platform, async reload ordering;
widget dropdown appears only for Games and selection updates grid. Include a
long label at small width/large text. Reuse existing support. No broad test churn.
Capture closed/open menu renders at390x844 and320x568@1.6 in the NEW evidence
directory; don't overwrite historical docs evidence. Check formats/analyzer,
focused tests then full suite once after stable changes (397tests baseline).

Build0.4.1+6APK using previous fresh Gradle --no-daemon --no-watch-fs with JBR21,
Flutter /Users/ghijs/development/flutter and Android SDK /Users/ghijs/Library/Android/sdk.
Save deliverables/lyberry-0.4.1-debug.apk and SHA. Emulator install -r/launch smoke
if available, preserving collection/keys. Do not add/delete existing device items
just to populate the dropdown; seeded widget renders test choices. No live API
tests or credential access needed. Existing session cache write grants may persist;
report actual permission blocks without bypass. Root packages source after review.

Finish your internal discovery/implementation/test/debug loop and return one
ready-for-review report with exact changes/test counts/evidence/APKhash. Checkpoint
only on a genuine block/interruption. No commit/push/deploy/account work. This is
one coherent phase; no progress polling or extra worker setup is needed.
