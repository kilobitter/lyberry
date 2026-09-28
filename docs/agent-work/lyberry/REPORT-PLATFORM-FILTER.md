# REPORT-PLATFORM-FILTER — Games platform filter (0.4.1+6)

- **STATUS:** ready_for_review (post-review correction cycle applied, see §10)
- **Task ID:** PLATFORM-FILTER
- **Workspace:** `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
- **Baseline:** `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/platform-filter-pre-041`
  (465 curated files + `BASELINE.json`)
- **Brief:** `docs/agent-work/lyberry/BRIEF-PLATFORM-FILTER.md`

## 1. What changed

### Controller (`lib/state/library_controller.dart`)

| Member | Line | Behaviour |
| --- | --- | --- |
| `platformFilter` | 71 | Transient selection next to `mediumFilter`/`search`; `null` means All platforms. Not persisted. |
| `availableGamePlatforms` | 74 | Unmodifiable, sorted option list derived from every saved game. |
| `hasFilters` | 79 | Now includes the platform predicate, so the Results/Recently-added header and Clear filters stay consistent. |
| `setMediumFilter` | 134 | Leaving Games drops the platform selection in the same assignment. |
| `setPlatformFilter` | 145 | Maps a requested value onto a stored option (`_resolvePlatformOption`), so blank/unknown input becomes All. |
| `clearFilters` | 153 | Clears search, medium and platform together. |
| `_reload` | 235 | Captures `requestedMedium`/`requestedSearch`/`requestedPlatform`, reads search results plus an unfiltered games-only list, and applies all results under the existing `_loadToken` guard. |
| `_resolvedOption` | 305 | The exact option from the refreshed list matching the captured selection case-insensitively, or `null`. `_reload` publishes this resolved string, so the value is identical (`==`) to a dropdown item even when only the casing changed. |
| `_platformsFrom` | 273 | Games only; blanks skipped; whitespace collapsed; deduplicated case-insensitively; `_caseScore` ranks mixed case (2) above all-upper (1) above all-lower (0) and the first-seen spelling wins a tie; sorted case-insensitively. |
| `_filterByPlatform` | 324 | Applies the normalised platform predicate to the already search/medium-filtered rows; games with no platform stay visible under All. |

Options are recomputed on every reload, so create/update/delete/import are picked
up. A casing- or whitespace-only change keeps the logical filter but republishes
the refreshed spelling; if the selected platform truly no longer exists (its
last entry was deleted or re-pointed), the same reload falls back to All and
shows the unfiltered game search results — no missing-value assertion and no
stale filtered grid. Reload options come from a second unfiltered
`listItems(medium: game)` read; the repository interface, SQL schema and
`item.platform` values are untouched.

### UI (`lib/ui/screens/home_screen.dart`)

- The Platform control (`_platformDropdown`, line 147, key `home-platform`) is
  inserted directly below `MediumTabs` and only when
  `controller.mediumFilter == MediaType.game` (line 101).
- Full width of the content column, `isExpanded: true` with an ellipsised label
  so a long console name cannot overflow at 320 px with 1.6x text.
- The `DropdownButton` value is guarded by **exact** membership in the option
  list (`options.contains(selected)`), because `DropdownButton` resolves its
  value with `==`; a stale string can no longer reach its item assertion.
- `onChanged` is `null` when no saved game names a platform, which keeps the
  control visibly disabled while All platforms stays the readable state; games
  without a platform remain listed under All.
- Uses the established dark/red theme (`InputDecorator` + `DropdownButtonHideUnderline`,
  no stock form-field chrome) and the existing `InputDecoration` label style.
- The approved Redline/Oxanium visual direction is unchanged.

### Version

- `pubspec.yaml:6` → `version: 0.4.1+6`.
- `lib/ui/screens/settings_screen.dart:188` → `Lyberry 0.4.1`.
- `README.md` → new Games-platform-filter feature bullet, 0.4.1 validation and
  APK entries, and an explicit note about the `dart format` analytics artifact.

No metadata, auth, network, backup or database-schema code was touched. The
grep-level diff against the baseline is exactly: `lib/state/library_controller.dart`,
`lib/ui/screens/home_screen.dart`, `lib/ui/screens/settings_screen.dart`,
`pubspec.yaml`, `README.md`, `test/ui/platform_filter_test.dart` (new),
`test/golden/platform_filter_render_test.dart` (new), three new
`test/golden/goldens/platform_filter_*.png`, the refreshed
`test/golden/goldens/settings_games_keys_390x844.png` (version label), the
additive test-only hook in `test/support/in_memory_repository.dart`, and the new
`docs/agent-work/lyberry/evidence/platform-filter/` files.

## 2. Tests

`test/ui/platform_filter_test.dart` (13 tests):

1. `come from games only, deduped, sorted, blanks skipped` — a book/CD platform
   and a whitespace-only value never appear; `PlayStation 4` / `playstation 4`
   collapse to one readable option; ordering is alphabetical.
2. `are empty outside the Games tab`.
3. `combines with search and All removes only the platform` — platform AND text
   search, then All removes only the platform predicate.
4. `a blank or unknown platform resolves to All`.
5. `leaving Games and clearing filters reset the selection`.
6. `deleting the last entry on the selected platform falls back` (line 213) —
   one PlayStation entry is re-pointed at another console and the other deleted
   in a single reload: the option disappears, the selection falls back to All in
   that same reload, and the remaining games return.
7. `a stale reload cannot overwrite a newer selection` — uses the injected
   `listItemsDelay` to hold a reload open, then changes the selection.
8. `appears only for Games and filters the grid` (widget).
9. `is disabled when no game names a platform` (widget).
10. `a long platform name fits 320px at 1.6x text` (widget, 320x568 @1.6).
11. `prefer mixed case and a readable fallback for duplicates` — mixed/upper/lower
    spellings of one platform in three insertion orders all yield
    `PlayStation 4`; with no mixed spelling, `NES`/`nes` resolves to `NES` in
    both directions (abbreviation preserved, stored values never rewritten).
12. `a casing-only option change keeps the exact refreshed value` — delete the
    entry carrying `PlayStation 4` while `playstation 4` remains: options become
    `['playstation 4', 'Super Nintendo']`, `platformFilter` becomes
    `'playstation 4'` (exact option) and the one matching game stays listed.
13. `keeps a valid exact selection when the spelling changes` (widget) — the
    same transition through the Home dropdown: no exception, `DropdownButton.value`
    is `'playstation 4'`, and the grid keeps the correct game.

(Test 1 is the regression that was written first and failed with
`Expected: 'PlayStation 4' / Actual: 'playstation 4'` before the `_caseScore`
fix; log `evidence/platform-filter/focused-tests.log`.)

## 3. Verification (all re-run on the final tree)

Log: `docs/agent-work/lyberry/evidence/platform-filter/final-verification.log`

| Command | Exit | Result |
| --- | --- | --- |
| `flutter test test/ui/platform_filter_test.dart test/golden/platform_filter_render_test.dart` | 0 | `+16: All tests passed!` |
| `flutter analyze` | 0 | `No issues found! (ran in 8.4s)` |
| `flutter test` (whole suite) | 0 | `+413: All tests passed!` (397-test 0.4.0 baseline + 16 new) |
| `dart --suppress-analytics format --set-exit-if-changed lib test` | 0 | `Formatted 134 files (0 changed)` |

Environment artifact: a bare `dart format --set-exit-if-changed …` prints
`Formatted 134 files (0 changed)` and then exits 1 because its post-run
`unified_analytics` upload throws in this network-restricted shell
(`AnalyticsImpl.send` stack trace). `dart --suppress-analytics format …` exits 0
with the same `0 changed` result, so formatting is clean and the non-zero exit
is not a formatting difference.

## 4. Renders and visual QA

Golden test `test/golden/platform_filter_render_test.dart` regenerates and
asserts, into the new directory only:

| File | Screen |
| --- | --- |
| `evidence/platform-filter/platform_filter_closed_390x844.png` | Games tab, closed control (390x844) |
| `evidence/platform-filter/platform_filter_open_390x844.png` | Games tab, open menu with seeded console options (390x844) |
| `evidence/platform-filter/platform_filter_open_320x568_scale1.6.png` | same, 320x568 @1.6x text (long label ellipsised, no overflow) |
| `evidence/platform-filter/settings_version_0.4.1_390x844.png` | Settings version row showing `Lyberry 0.4.1` |

All renders were inspected. The closed render shows the labelled `Platform`
group at full column width directly below the medium tabs with `All platforms`
and the caret. The open render overlays the menu with `All platforms`,
`PlayStation 4`, `Super Nintendo` and the long
`Super Nintendo Entertainment System - Su…` entry ellipsised rather than
clipped. The 320x568 @1.6x render keeps the same layout with the long label
ellipsised, and the Settings render shows the `Lyberry 0.4.1` version row.

Historical evidence was preserved: `evidence/games/settings_games_keys_390x844.png`
was restored byte-identically to the pre-phase copy after the version-label
refresh, and the refreshed golden is kept in the new directory as
`settings_version_0.4.1_390x844.png`.

## 5. Build

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
  ./gradlew assembleDebug --no-daemon --no-watch-fs --console=plain \
    -Ptarget-platform=android-arm,android-arm64,android-x64 \
    -Ptarget=lib/main.dart -Pbase-application-name=android.app.Application \
    -Pdart-obfuscation=false -Ptrack-widget-creation=true \
    -Ptree-shake-icons=false
```

`BUILD SUCCESSFUL in 20s` (log
`evidence/platform-filter/build-apk-0.4.1.log`). `aapt2 dump badging` reports
`package=app.lyberry.lyberry versionName='0.4.1' versionCode='6' minSdkVersion='24'
targetSdkVersion='36'`.

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.4.1-debug.apk` |
| Size | 201 059 210 bytes |
| SHA-256 | `63dc4d555ed4abdad8e604929311e9053a10f272a4b4c19592e6c5f07a4ebe0a` (+ `.sha256`, `shasum -c` OK) |

The build log for the corrected artifact is
`evidence/platform-filter/build-apk-0.4.1-correction.log`
(`BUILD SUCCESSFUL in 19s`, `:app:compileFlutterBuildDebug` re-ran). Its size is
consistent with the 0.4.0 deliverable (201 039 106 bytes); the earlier
pre-correction 0.4.1 file (176 194 900 bytes, SHA `6c5c1a82…`) was a partially
rebuilt artifact and is superseded by this one.

`lyberry-0.4.0-debug.apk`, 0.3.1, 0.3.0, 0.2.0 and all root-owned source
archives are untouched.

## 6. Device smoke (`emulator-5554`, Pixel 8a API 37)

| Step | Result | Evidence |
| --- | --- | --- |
| `adb -s emulator-5554 install -r deliverables/lyberry-0.4.1-debug.apk` | `Success` | `evidence/platform-filter/device-install.log` |
| `am start -n app.lyberry.lyberry/.MainActivity` | `topResumedActivity=…/.MainActivity`, `pidof` returns a pid | `device-install.log` |
| Games tab selected | Platform group appears directly below the medium tabs; seeded collection has no games, so All platforms is present and disabled; Results shows `0 items` with the real no-matches state | `device-01-games-tab-no-platforms.png`, `ui-01-games.xml` |
| Tap the disabled control | Nothing opens (only `Platform` / `All platforms` nodes remain) and logcat has no exception (`fatal_or_anr_lines=0`) | `device-02-…png`, `ui-02-…xml` |
| Back to All | Control and label disappear, grid returns to `1 item` | `ui-03-back-to-all.xml` |
| Collection preserved | `run-as … cat databases/lyberry.db` → `items = 1` (the pre-existing "Emulator Smoke Test Book" copy; nothing added or removed) | `device-04-lyberry.db` |
| Corrected artifact: `adb install -r` | `Success`, `versionName=0.4.1`, `versionCode=6`, `topResumedActivity=…/.MainActivity` | `device-install-correction.log` |
| Corrected artifact: Games tab then All | Platform group present under the medium tabs; returning to All removes it; `1 item` in both the whole-library count and the preserved collection | `device-05-corrected-games-tab.png`, `ui-05-corrected-games.xml`, `ui-06-corrected-all.xml` |
| Corrected artifact: collection + crash check | `items = 1` (`['Emulator Smoke Test Book']`); `FATAL EXCEPTION`/`E/flutter`/duplicate-key line count `0` | `device-07-lyberry-correction.db`, logcat |

The dropdown options themselves are exercised by the seeded widget/golden tests
because the brief forbids adding device items just to populate the control.

## 7. Known limitations / risks

- No saved game exists on the emulator, so the on-device run shows the
  **disabled** control and the All-platforms state only. Options, menu opening
  and filtering are covered by the seeded widget and render tests, not by a
  device tap on a real option.
- The option list is derived per reload with a second games-only `listItems`
  call; for very large libraries this doubles one read while Games is selected.
  This is the brief's accepted design (no new query interface/SQL migration).
- Platform values are not normalised in storage; only the displayed option
  list deduplicates case-insensitively, and no aliases are invented, so
  `PS4` and `PlayStation 4` remain two options by design.

## 8. Decisions for Astra

- None required. `test/golden/failures/` holds transient golden-diff scratch
  output produced while regenerating the version-label golden; it is a test-run
  artifact directory, not source, and can be excluded from packaging.

## 9. Next checkpoint

Phase complete and ready for acceptance review. Remaining P2-or-later work is
unchanged and out of this brief: live provider coverage without supplied
credentials, camera/gallery/native-picker device testing, `xcrun simctl` (not
installed) and iOS runtime behaviour.

## 10. Correction cycle (review 1)

`docs/agent-work/lyberry/REVIEW-PLATFORM-FILTER.md` (baseline
`work/baselines/platform-filter-review1`) raised two findings; both are fixed in
this artifact.

**P1 — the selected value must exactly match the refreshed option.** Before the
fix, `_reload` tested the old spelling with `_hasPlatform` (case-insensitive) and
republished it, and Home's `_hasOption` guard was case-insensitive too, so the
obsolete `PlayStation 4` string reached `DropdownButton`, whose item lookup is
`==`. `_reload` now publishes `_resolvedOption(platforms, requestedPlatform)` —
the exact refreshed spelling — and Home's guard is exact membership
(`options.contains(selected)`). The logical filter still survives a casing-only
change: deleting the entry spelled `PlayStation 4` while `playstation 4` remains
keeps the filter active with `platformFilter == 'playstation 4'` and the same
result row.

**P2 — capitalization preference.** `_caseScore` counted uppercase letters, so
shouted `PLAYSTATION 4` beat `PlayStation 4`. It now ranks mixed case (2) above
all-upper (1) above all-lower (0), keeps the first-seen spelling on a tie, and
still never rewrites the stored `item.platform` value, so abbreviations such as
`NES` survive.

Regressions written first and observed failing (log
`evidence/platform-filter/regression-before-fix.log`, exit 1):

```
platform options prefer mixed case and a readable fallback for duplicates [E]
  Expected: ['PlayStation 4']  Actual: ['PLAYSTATION 4']
platform predicate a casing-only option change keeps the exact refreshed value [E]
  Expected: 'playstation 4'    Actual: 'PlayStation 4'
home dropdown keeps a valid exact selection when the spelling changes [E]
  Expected: null
  Actual: _AssertionError:<'package:flutter/src/material/dropdown.dart': Failed
    assertion: … There should be exactly one item with [DropdownButton]'s value:
```

After the fix, the same file passes (log `regression-after-fix.log`, exit 0),
the three renders are unchanged, and the full suite is green at 413. The APK was
rebuilt, reinstalled over the existing data and re-checked on `emulator-5554`
(§6); README, checksums and this report carry the new values.
