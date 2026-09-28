# PHOTO-COVER — implementation contract

## Objective and design

Let an owned copy use one of its personal photos as its main/cover image, with
interactive cropping and quarter-turn rotation first. Apply to every medium.
Keep the existing dark/red visual language and the original photo unchanged.
Deliver 0.7.0+9, Android APK and source handoff. Android emulator-5554 is online.

Use the existing content-addressed MediaAsset and coverAssetId/photoAssetIds
storage. Save a derived image as the cover, with the source photo still in the
personal photo list. No database/backup schema change is needed (both remain 2).
The existing image package is already installed; use it plus Flutter UI rather
than adding a native crop dependency, new permissions or a network service.

## User flow and invariants

1. In Edit copy, each existing/new personal photo has a clear accessible action
   such as Use as cover. Open a dedicated crop preview with the chosen image.
   Cover Camera/Library actions should use this same preview too. A new source
   captured/picked through those cover actions is retained as a personal photo
   upon applying; dedupe it, respect the 20-photo limit (explain before capture
   if full, and allow choosing an existing photo).
2. Preview offers a visible draggable/resizable crop rectangle, 90-degree rotate
   left/right (or a single labelled clockwise action), Reset, Cancel/back and
   Use as cover. Free rectangular crop is sufficient; optional aspect presets
   are allowed but perspective correction/filters/arbitrary-angle rotation are
   outside this phase. Start with the full oriented image selected. A drag must
   actually affect saved pixels, not only the visible overlay. Keep controls
   usable on 320x568 at 1.6 text scale; meaningful labels and touch targets.
3. Crop coordinates are relative to the orientation-corrected, quarter-turned
   image. Preview and final output MUST match for EXIF-rotated/mirrored JPEGs,
   portrait/landscape inputs, and every quarter turn. Reset returns full source
   in its natural EXIF orientation. Reject empty/non-finite/out-of-bounds crops.
4. Applying returns a validated derived MediaAsset to the editor draft; it does
   not persist until Save copy. Original stored/pending photo bytes and IDs
   remain unchanged. Cancelling the crop or editor changes no persisted data.
   Failed load/transform shows a useful error and preserves the previous cover.
   A photo can be cropped again from its unchanged original. Removing a photo
   must not clear its separately derived cover. Removing cover keeps photos.
5. New manual cover intent wins over late provider-cover downloads. Use the
   existing generation guards and lifecycle checks, with stale async transform
   results discarded. Avoid duplicate camera/crop/save operations; disable
   conflicting controls during photo loading/processing/saving. Never pop a
   different route when a late operation returns. Save only referenced new
   assets if needed to avoid retaining abandoned intermediate cover renders.
6. Run expensive decode/transform/encode work off the Flutter UI thread. Preserve
   ImageInspector bounds (5MiB/20MP, supported static JPEG/PNG/WebP) before full
   raster work; no uncontrolled decode or image-bomb bypass. Normalize EXIF once,
   strip capture/GPS metadata in the derived image, constrain output dimensions
   to a reasonable maximum (existing camera max2560 is appropriate), validate
   the encoded output through MediaAsset.fromBytes. Never upload photos.
7. Save/reopen/relaunch and export/import use the derived cover and unchanged
   source photo through existing asset references. Keep Finished, notes, reviews,
   ratings, metadata, games platform filtering and all provider flows intact.

## Scope and ownership

Workspace: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
Baseline (no Git repo): parent work/baselines/photo-cover-pre-070, 590 curated
files copied from current 0.6.0 tree with BASELINE.json. Preserve prior changes.

Flash owns discovery and implementation within: editor_screen.dart; new crop UI
screen/widgets; new image-transform service and its model/helper as appropriate;
app_services.dart only if injection is useful; small related lifecycle/controller
adjustments; tests/support/fixtures/current goldens for this feature; pubspec.yaml,
Settings version label, generated android/local.properties version values;
README feature note and docs/agent-work/lyberry/REPORT-PHOTO-COVER.md; evidence under
docs/agent-work/lyberry/evidence/photo-cover/. Avoid DB/model/backup changes unless
a concrete necessity is raised to Astra. No dependency or credential changes.

You are not alone in the codebase. Do not revert others' edits; accommodate them.
Astra owns this brief, acceptance/review/checkpoint and final archive packaging.
No further agents, orchestration skill invocation, git commits/push/deploy, auth
changes, real API calls, paid probes or permissions bypasses.

## Dependency-ordered implementation and evidence

Implement one vertical bundle: transform contract + unit tests; editor/preview
integration + widget/persistence tests; visual/full validation; Android build and
emulator smoke. Continue debugging internally within scope. Return one concise
report after the loop, or a precise environment blocker with implementation done
and exact remaining commands. Do not spend a separate turn polishing long docs.

Tests should exercise real pixels (asymmetric coloured fixture, EXIF orientation,
quarter turns, crop edges and output bounds), cancel/reset/error/lifecycle/late
cover races, existing versus newly picked photo flows, draft Save boundaries,
original-photo preservation and real SQLite backup round-trip. Test behaviours,
not implementation replicas. Include normal and narrow/large-text crop renders.
Run focused tests then analysis, format and full suite once after debugging.
Update only expected current goldens; retain old evidence PNGs unchanged.

Toolchain: Flutter /Users/ghijs/development/flutter; cached Dart SDK binary at
/Users/ghijs/development/flutter/bin/cache/dart-sdk/bin/dart; JBR21 at
/Applications/Android Studio.app/Contents/jbr/Contents/Home; Android SDK at
/Users/ghijs/Library/Android/sdk. Use flutter --suppress-analytics
--no-version-check test --no-pub and analyze --no-pub. Root's previous cache grants
did not reach the old child. This is a fresh child: try a needed command once;
if sandbox cache permission fails, do not repeat/request new permission or change
permissions. Use cached Dart for static checks, hand root the exact remaining
Flutter/Gradle/device commands with paths, and continue useful implementation.

Android build from android/ with JAVA_HOME=JBR21 and FLUTTER_SUPPRESS_ANALYTICS=true:
./gradlew assembleDebug --no-daemon --no-watch-fs --console=plain
-Ptarget-platform=android-arm,android-arm64,android-x64 -Ptarget=lib/main.dart
-Pbase-application-name=android.app.Application -Pdart-obfuscation=false
-Ptrack-widget-creation=true -Ptree-shake-icons=false
Sync generated Android version properties before building; verify APK version
0.7.0/code9 and all three ABIs. Final artifact deliverables/lyberry-0.7.0-debug.apk
plus checksum (root can execute commands if cache blocked).

## Emulator acceptance (explicitly requested)

Use only online emulator-5554 (offline5562 is unrelated). Install with adb -s
emulator-5554 install -r; never uninstall, clear data or reset the emulator. Preserve
existing library and keys; record only necessary counts/version information, not
private record contents. If a backup is needed, keep it in parent work/private/
and never include it in evidence/archive. Create a clearly labelled test copy via
UI and a deterministic asymmetric fixture photo or emulator camera. Exercise
select existing personal photo, crop/rotate/apply, save, detail/home cover,
reopen after app restart, and cancellation; capture clear relevant screenshots
and runtime error check. Remove only our test copy if cleaning up; never delete
pre-existing records. Compare original photo versus derived cover bytes/dimensions
where feasible. Also smoke the already shipped Finished field while here.
Astra reviews actual evidence; no need to wait for permission for this authorised
local build/test. Device denied/offline/tool block: report exact state honestly.

## Handoff

Concise REPORT-PHOTO-COVER.md: changed files/contracts, actual commands and exits,
meaningful test counts, screenshot paths, APK identity/hash if built, device checks
and real limitations. Status ready_for_review or ready_for_commands if blocked.
Root finalizes validation docs, reviews once with both lenses and packages source;
no follow-up docs-only worker phase. Keep logs local rather than streaming them.
