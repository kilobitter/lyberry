# REPORT-PHOTO-COVER — personal photo covers, crop + rotate (0.7.0+9)

**Final status: accepted.** See `ACCEPTANCE-PHOTO-COVER.md` for root execution: 78 focused tests passed, crop renders accepted, APK built and tested on the emulator. Final full suite intentionally skipped per user request.

**Historical worker handoff:** The review corrections in
`REVIEW-PHOTO-COVER.md` are implemented. This worker can run only the cached
Dart SDK: every `flutter` invocation dies writing `bin/cache/engine.stamp` and
the `adb` daemon cannot bind its socket, so the Flutter suite, the Gradle APK and
the emulator smoke stay with root (see `evidence/photo-cover/sandbox-blockers.txt`
and `remaining-commands.sh`). No cache or adb retry, no permission request.

Brief: `BRIEF-PHOTO-COVER.md`. Review: `REVIEW-PHOTO-COVER.md`.
Evidence: `evidence/photo-cover/` (initial failures preserved as `*-initial.log`).
Baseline: `work/baselines/photo-cover-pre-070`; correction baseline
`work/baselines/photo-cover-review1`. No Git repository, so nothing was staged or
committed.

## 1. What changed

| Area | File | Change |
| --- | --- | --- |
| Crop model | `lib/domain/cover_crop.dart` (new) | `CoverCrop` — normalized rectangle plus 0-3 clockwise quarter turns; empty, non-finite, out-of-range and out-of-bounds crops are rejected; `toPixels` clamps a sliver to a real pixel region |
| Renderer | `lib/domain/cover_renderer.dart` (new) | Pure-Dart pipeline: canonical inspector guard, decode, bake EXIF orientation once, quarter turns, crop in oriented space, bound the longest side to 2560, clear EXIF/ICC, re-encode JPEG; builds the interactive preview and its rotations; `deriveCoverAsset` returns a verified `MediaAsset` so the final decode, digest and bound check run on the same isolate as the pixels |
| Worker + service | `lib/services/image_transform.dart` (new) | `ImageTransformService`; `IsolateImageRenderWorker` runs render **and** asset validation through `compute` (off the UI thread), `InlineImageRenderWorker` runs the identical code for tests; `deriveCover` no longer decodes or hashes on the calling isolate |
| Crop UI | `lib/ui/screens/cover_crop_screen.dart` (new) | Full-screen preview of the orientation-corrected, quarter-turned image, draggable/resizable crop rectangle with corner handles and a rule-of-thirds grid, Rotate left / Rotate right / Reset / Cancel / Use as cover, a stable error state with Retry and Cancel, route-ownership guard so a late render never pops the route underneath, controls disabled while loading/rendering/leaving |
| Editor | `lib/ui/screens/editor_screen.dart` | Labelled `Use as cover` on every personal photo with a real 48dp target; Cover Camera/Library and that action share the crop preview; a new cover source is kept as a personal photo, deduplicated by reference, capped with a re-check at adoption, and explained before capture when the list is full; manual intent is claimed before the async load; removing a photo never clears a derived cover; Save writes only referenced assets; `_mediaBusy` serialises capture/cover/remove/lookup/save |
| Canonical safety | `lib/domain/image_inspector.dart` | The final raster comparison now accepts the **exact transpose** when the file is a JPEG whose own pre-decode EXIF orientation is 5-8 (`img.decodeJpgExif`), so honest rotated/mirrored photos ingest. Raw header dimensions, every header/decoder/bitstream agreement, animation, chunk, byte and pixel guard are unchanged; PNG and WebP keep the strict comparison |
| Services | `lib/app_services.dart` | `AppServices.images` (default isolate worker) |
| Version | `pubspec.yaml`, `lib/ui/screens/settings_screen.dart`, `android/local.properties` | `0.7.0+9` (`Lyberry 0.7.0`, `flutter.versionName=0.7.0`, `flutter.versionCode=9`) |
| Docs | `README.md` | Feature bullet for personal photo covers |
| Tests | `test/domain/cover_crop_test.dart`, `test/services/image_transform_test.dart`, `test/ui/photo_cover_flow_test.dart`, `test/data/photo_cover_backup_test.dart`, `test/golden/photo_cover_render_test.dart`, `test/support/photo_fixtures.dart` (new); `test/domain/image_safety_test.dart`, `test/services/image_ingest_test.dart`, `test/support/test_support.dart`, `test/ui/library_flow_test.dart` | 55 unit tests + 17 widget tests + 3 renders (see §3) |
| Evidence | `tool/photo_cover_pixel_check.dart` (new), `docs/agent-work/lyberry/evidence/photo-cover/` | Executable pixel/safety harness plus the logs |

No database, backup-schema, dependency, credential, auth or provider change:
both schemas stay at version 2, and the derived cover is a normal
content-addressed `MediaAsset` reached through `coverAssetId`.

**Paths this worker touched** (verified by byte-comparing against
`work/baselines/photo-cover-pre-070`):

- Modified: `README.md`, `pubspec.yaml`, `lib/app_services.dart`,
  `lib/domain/image_inspector.dart`, `lib/ui/screens/editor_screen.dart`,
  `lib/ui/screens/settings_screen.dart`, `test/domain/image_safety_test.dart`,
  `test/services/image_ingest_test.dart`, `test/support/test_support.dart`,
  `test/ui/library_flow_test.dart`, `android/local.properties`.
- Added: `lib/domain/cover_crop.dart`, `lib/domain/cover_renderer.dart`,
  `lib/services/image_transform.dart`, `lib/ui/screens/cover_crop_screen.dart`,
  `test/domain/cover_crop_test.dart`, `test/services/image_transform_test.dart`,
  `test/ui/photo_cover_flow_test.dart`, `test/data/photo_cover_backup_test.dart`,
  `test/golden/photo_cover_render_test.dart`, `test/support/photo_fixtures.dart`,
  `tool/photo_cover_pixel_check.dart`, this report and
  `docs/agent-work/lyberry/evidence/photo-cover/*`.
- Untouched but different from the curated baseline because root or an earlier
  phase wrote them: `docs/agent-work/lyberry/CHECKPOINT.md`,
  `BRIEF-PHOTO-COVER.md`, `REVIEW-PHOTO-COVER.md`, `deliverables/*`, `build/`,
  `android/.gradle/`, `android/.kotlin/`, generated plugin registrants,
  `.iml`/`.flutter-plugins-dependencies`, earlier-phase evidence and
  `test/golden/failures/*`.

## 2. Verification actually run here

Cached Dart SDK (`/Users/ghijs/development/flutter/bin/cache/dart-sdk/bin/dart`),
logs in `evidence/photo-cover/`.

| Command | Exit | Result |
| --- | --- | --- |
| `dart --suppress-analytics analyze lib test tool` | 0 | `No issues found!` (`dart-analyze.log`) |
| `dart --suppress-analytics format --output=none --set-exit-if-changed lib test tool` | 0 | `163 files (0 changed)` (`dart-format-check.log`) |
| `dart --suppress-analytics run tool/photo_cover_pixel_check.dart` | 0 | **144 checks, 0 failures** (`pixel-check.log`) |
| `flutter ... test --no-pub <focused>` (before the fix) | 1 | Sandbox denial, not a test result (`flutter-test-attempt.log`) |
| `adb devices` | 1 | Sandbox denial: `could not install *smartsocket* listener` (`adb-devices.log`) |

The harness runs the real production code against real bytes and now covers:
crop validation (empty, NaN/infinity, out-of-bounds, out-of-range turns); a
full-frame round trip; the four quadrant colours; a dragged crop that changes
saved pixels; all four quarter turns; EXIF orientation 6 with preview/output
agreement on a coarse grid; a crop mapped inside the oriented space; the 2560
bound on a 3200x2400 source; no upscaling; metadata stripping; deterministic
content-addressed ids; **EXIF ingest for orientations 1-8** (verified asset, raw
stored size, baked decode, oriented cover); and the canonical safety guards -
JPEG pixel bomb, conflicting duplicate PNG header, PNG chunk pile, animated PNG
and WebP, WebP canvas below its bitstream and a WebP canvas bomb.

## 3. Tests

| File | Cases | Covers |
| --- | --- | --- |
| `test/domain/cover_crop_test.dart` | 11 | Full-frame validity, all four turns, empty/negative/out-of-bounds/non-finite rejection, floating-point edge tolerance, `assertValid`, pixel mapping and clamping, value semantics |
| `test/services/image_transform_test.dart` | 17 | Service wraps the renderer byte-for-byte; the real isolate worker derives the same **verified** asset as the inline worker; the source is never mutated; different crops give different ids; dragged crops change pixels; both turn directions; EXIF normalized once with preview/output agreement; oriented-space crop; **an EXIF original ingests raw and crops to the oriented frame**; bounds; metadata stripping; rejection of bad crops, non-images and over-limit sources |
| `test/ui/photo_cover_flow_test.dart` | 17 | Stored photo becomes the cover with the original preserved and the drag narrowing saved pixels; picked photo becomes a personal photo; cancel keeps the previous cover; removing a photo keeps the derived cover; removing the cover keeps the photos; 48dp photo action; full list explains before capture and offers the existing photos; manual cover beats a late provider download (**stored id is the expected derived asset**); manual intent wins while the source bytes are still loading; a capture in flight blocks a second action and Save; **a source load that outlives the editor never pushes the crop screen**; a source removed from the draft comes back when picked for the cover; cancelling the editor writes nothing; stable error state with Retry/Cancel; a failed apply can be retried; a render finishing during the back transition never pops the editor; 320x568 at 1.6x text |
| `test/data/photo_cover_backup_test.dart` | 4 | Derived cover and original survive close/reopen in real SQLite; export/merge into a second database; dropping the photo reference leaves the cover; **`SnapshotCodec` encode/decode round trip of an EXIF original plus derived cover**, verified after reopen |
| `test/domain/image_safety_test.dart` | 16 (was 6) | All existing negative fixtures (PNG/JPEG bombs, conflicting headers, WebP canvas, animation, chunk pile, asset verification) plus orientations 1-4 and 5-8 ingest, mirrored quarter turns, and the allowance staying JPEG-only |
| `test/services/image_ingest_test.dart` | 7 (was 6) | Existing ingest rules plus an EXIF-rotated JPEG ingesting as a verified asset with raw dimensions |
| `test/golden/photo_cover_render_test.dart` | 3 renders | `photo_cover_crop_390x844.png`, `photo_cover_crop_rotated_390x844.png`, `photo_cover_crop_320x568_scale1.6.png`, now rendered with `buildLyberryTheme()` and the platform text-scale path |

Route handling in the UI tests no longer relies on fixed pumping: `applyCrop`
asserts the Apply button is enabled and no error is shown, waits until
`CoverCropScreen` actually leaves the tree (reporting the on-screen error text if
it does not), and `saveEditor` asserts the crop route is gone, Save is enabled
and the `Copy updated.` confirmation appeared - so a missed tap can no longer
look like a pass. The `reveal` helper now scrolls the editor's own `ListView`
Scrollable instead of a text field's hidden one, which removes the wrong-target
drag warnings from the initial run.

## 4. Review corrections, item by item

1. **Canonical EXIF ingest (P1).** `ImageInspector.inspect` keeps every existing
   guard and only accepts the exact transpose when `img.decodeJpgExif` reports
   orientation 5-8 for a JPEG; `InspectedImage` still reports the raw header
   dimensions. `CoverSourceGuard` and its duplicate header parser were deleted;
   `CoverRenderer._decodeOriented` runs `ImageInspector.inspect` before any
   raster work. Covered by the new safety tests, the ingest test and the harness
   (orientations 1-8 plus every negative fixture).
2. **Completion/cancellation race (P1).** `CoverCropScreen` tracks `_closing`
   (set by `PopScope` for back gestures and by `_close()` for Cancel/Apply) and
   checks `_leaving`, `mounted` and `ModalRoute.isCurrent` before popping, so a
   render that finishes during the reverse transition cannot pop the editor.
   Regression test: "a render finishing during the back transition never pops
   the editor".
3. **Main-isolate decode (P2).** `ImageRenderWorker.renderCover` now returns a
   verified `MediaAsset` produced by `CoverRenderer.deriveCoverAsset` inside the
   worker; the isolate path is covered by asserting `contentVerified` on the
   isolate result, and the repository's verified-content optimization still
   applies.
4. **Ownership and original retention (P2).** `_addPhoto` now owns `_photoBusy`
   with try/finally, the cap is re-checked at adoption, capture/cover/remove/
   lookup/save controls and handlers all respect `_mediaBusy`, the manual
   generation is claimed before the camera or photo load, and `_openCoverCrop`
   dedupes photo references with `_photoIds` (so a removed original returns, or
   a source matching the derived cover still joins the list). Four new widget
   tests cover deferred capture, the removed-then-repicked source, manual intent
   during the source load, and Save/act-in-flight serialisation.
5. **Failing test and assertions.** The picked-photo test now uses the
   deterministic `applyCrop`/`saveEditor` helpers and asserts the real stored
   outcome; the late-provider test requires the exact derived asset id, the
   unchanged photo reference and a real download request; the cancel and removal
   tests prove Save executed; `photo_cover_backup_test` serialises and decodes
   through `SnapshotCodec` before merging an EXIF original and its derived cover.
6. **Error and visual evidence.** A failed preview is a stable error state with
   Retry and Cancel and no spinner; a failed apply keeps the old cover, can be
   retried and is covered by a test; the photo action is a real 48dp target; the
   three crop goldens use `buildLyberryTheme()` and the real text-scale path.

Correction-bundle delta, byte-compared against
`work/baselines/photo-cover-review1` (13 files, all in this scope):
`lib/domain/image_inspector.dart`, `lib/domain/cover_renderer.dart`,
`lib/services/image_transform.dart`, `lib/ui/screens/cover_crop_screen.dart`,
`lib/ui/screens/editor_screen.dart`, `test/domain/image_safety_test.dart`,
`test/services/image_ingest_test.dart`, `test/services/image_transform_test.dart`,
`test/ui/photo_cover_flow_test.dart`, `test/ui/library_flow_test.dart`,
`test/data/photo_cover_backup_test.dart`,
`test/golden/photo_cover_render_test.dart`,
`tool/photo_cover_pixel_check.dart`.

### Second pass (root's focused run: 74 passed / 3 failed)

- `ImageTransformService.deriveCover` is `async` again, so an empty, non-finite
  or out-of-bounds crop still surfaces as a **Future** error. Only the cheap
  model check stays on the caller; the decode, digest and bound check still run
  inside the worker.
- The photo action is a real 48dp target again: `VisualDensity.compact` was
  shaving the 48dp minimum to 40, so the style now pins
  `VisualDensity.standard` with `minimumSize: Size(0, 48)`.
- Route transitions settle deterministically. `openEditor` and `reveal` use
  `pumpAndSettle` (the editor's own `ListView` Scrollable, so no stray drag
  warnings), while the crop route is awaited with bounded
  `pumpCropReady`/`pumpCropClosed` helpers, and the cancel, apply, retry and
  back-transition paths assert that the route actually left the tree.
- Editor route ownership: the editor now wraps its Scaffold in `PopScope`,
  `_draftAlive` guards every adoption after an await, and `_editorIsTop` guards
  the crop push, so a capture or photo load that outlives the editor can no
  longer push the crop screen over the detail route. New regression test:
  "a source load that outlives the editor never pushes the crop screen".
- `_addPhoto` dedupes on photo membership (`_photoIds`) only, so a pending photo
  that was removed from the draft can be added again normally.

## 5. Handoff

`evidence/photo-cover/remaining-commands.sh` (run with `bash`) holds the ordered
commands: focused tests including the canonical safety suites, golden
regeneration, `flutter analyze`, the format check, the full suite, the Gradle
`assembleDebug` recipe from `android/` with JBR21 and the three ABIs, the APK
identity/checksum checks, and the emulator-5554 install plus screenshot,
relaunch, cancel and Finished smoke.

Goldens: the three `photo_cover_*` renders are new. Version-bump goldens are
`test/golden/goldens/settings_movies_keys_390x844.png` (the `Lyberry 0.7.0`
row, ~66px) and `test/golden/goldens/editor_finished_390x844.png` (the photo
actions changed the editor's geometry). Root inspects and regenerates only those
exact files; the 101 historical evidence PNGs stay untouched.

## 6. Outstanding risks

- The Flutter suite and the three crop goldens have still never executed here.
  Everything type-checks (`dart analyze` clean over `lib`, `test`, `tool`) and
  the pixel core plus the canonical safety path are executed evidence, but route
  timing, drag hit-testing and golden pixels need one real `flutter test` run.
- The exact cause of the original missed Save in
  `photo-cover-focused-initial.log` could not be reproduced without the Flutter
  engine. The harness now fails loudly with the on-screen error text if the crop
  route does not close, so a remaining product defect will be visible in root's
  next run instead of silently passing.
- Device coverage stays unverified: install/relaunch/cancel, the real camera and
  picker, and the export/import file path were not exercised.
- A rotate on a very large photo still costs about a second on device (one
  bounded decode per turn on the background isolate); the interactive rotation
  reuses the bounded preview instead of re-decoding the original.
