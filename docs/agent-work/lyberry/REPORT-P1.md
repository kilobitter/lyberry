# LYB-P1 completion report

STATUS: ready_for_review (correction cycles 1 and 2 complete)
Task ID: LYB-P1
Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
Date: 2026-09-23

## What was built

Working local Flutter collection slice (Android + iOS project, no Git, no P2
features). First launch is empty; every copy is manual CRUD against a real local
SQLite file; photos are stored as bytes inside that file.

- Domain: immutable `MediaItem` (one owned copy) and `MediaAsset` (content
  addressed by lowercase SHA-256) with the DESIGN field contract, half-star
  rating rules, year/barcode/string bounds, ISBN-10/13, EAN-8/13 and UPC-A
  checksum validation, and UTC ISO-8601 timestamps.
- Storage: `sqflite` schema v1 (`media_items`, `media_assets`), injected
  `DatabaseFactory` + `DatabaseLocation`, transactions for item+asset writes,
  repository-enforced asset references, newest-first listing, SQL search over
  title/creator/publisher/description/review/notes/barcode, medium filter,
  copy/delete, snapshot export and atomic merge. Unreferenced asset rows are
  retained on purpose (no blob deletion in v1).
- Services: injected `PhotoSource` (`image_picker`, downscale 2560 px at quality
  90), `ImageIngest` (magic-byte container check, decode, 5 MiB and 20 MP
  bounds), Android lost-data recovery surfaced as a user notice.
- UI: Redline palette on `#111416`, bundled Oxanium for brand and headings,
  native sans for body text, 4 px corners, thin rules. Home has the masthead,
  real copy count, search, wrapping medium tabs and a two-column cover grid with
  empty, no-results and error states plus pull to refresh. Detail shows cover,
  rating, review, notes, photos, metadata, edit, add another copy and delete
  confirmation. Editor covers medium, required title, creator, year, publisher,
  barcode/ISBN, description, platform for games, rating, review, notes, cover and
  up to 20 photos with inline validation. Scan is an honest phase-2 placeholder
  and Settings is minimal app info.
- Bottom bar: Library / prominent red Scan pill / Settings, >=48 dp targets,
  semantic labels, dark system UI. Scanning and metadata lookup are never faked.

Font: `Oxanium[wght].ttf` and `OFL.txt` downloaded from the official Google Fonts
repository (`ofl/oxanium`) and bundled offline under `assets/fonts/oxanium/`.
SHA-256 font `2ce01d94...babb0`, licence `fe17c0f2...6336b`. No runtime fonts.

## Changed paths (worker-owned)

Created: `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `README.md`
(Flutter default, untouched), `android/**` and `ios/**` from `flutter create`,
`.metadata`, `.gitignore`, `lyberry.iml`, `.idea/**`.

App code, 38 Dart files under `lib/`:

- `lib/main.dart`, `lib/app.dart`
- `lib/domain/`: `media_type`, `media_item`, `media_asset`, `library_snapshot`,
  `validation`, `barcode`, `timestamps`, `ids`, `clock`, `collection_utils`,
  `image_inspector`
- `lib/data/`: `database`, `database_location`, `media_repository`,
  `sqlite_media_repository`
- `lib/services/`: `image_ingest`, `photo_source`
- `lib/state/`: `item_draft`, `library_controller`
- `lib/ui/`: `theme`, `feedback`, `navigation`, `library_scope`
- `lib/ui/widgets/`: `masthead`, `medium_tabs`, `cover_tile`, `media_cover`,
  `star_rating`, `rating_input`, `state_views`, `bottom_bar`
- `lib/ui/screens/`: `home_screen`, `detail_screen`, `editor_screen`,
  `scan_screen`, `settings_screen`

Tests and evidence, 12 Dart test files plus goldens:

- `test/domain/validation_test.dart`, `test/domain/snapshot_test.dart`
- `test/domain/image_safety_test.dart` (header-first safety, WebP fixture,
  asset verification)
- `test/domain/immutability_test.dart` (read-only models)
- `test/services/image_ingest_test.dart`, `test/services/photo_source_test.dart`
- `test/data/sqlite_repository_test.dart`
- `test/ui/library_flow_test.dart`
- `test/golden/render_evidence_test.dart`
- `test/support/`: `test_support`, `in_memory_repository`, `failing_repository`
- `test/fixtures/sample.webp` (official Google WebP gallery sample, 320x214)
- `test/golden/goldens/`: `home_390x844.png`, `detail_390x844.png`,
  `editor_390x844.png`, `home_320x568_scale1.6.png`,
  `editor_320x568_rated_scale1.6.png`
- `docs/agent-work/lyberry/evidence/p1/*`

Platform config touched: `ios/Runner/Info.plist` (camera and photo-library
purpose strings).

Coordinator documents `DESIGN.md`, `PLAN.md`, `CHECKPOINT.md`, `PROVIDER-NOTES.md`
and `BRIEF-*.md` were read only and left untouched, as were the concept images
under `../lyberry-concepts`.

## Verification (command, exit status, result)

Every command used `/Users/ghijs/development/flutter/bin/flutter` with
`--no-version-check` and `FLUTTER_SUPPRESS_ANALYTICS=true`, because this sandbox
denies writes to `~/.dart-tool`; nothing else in the toolchain was changed.

1. `flutter pub get` -> 0. Resolved `sqflite 2.4.2+1`,
   `sqflite_common_ffi 2.3.7+1`, `image_picker 1.1.3`, `image 4.5.4`,
   `uuid 4.6.0`, `crypto 3.0.6`.
2. `dart format --output=none --set-exit-if-changed lib test` -> 0
   (47 files, 0 changed). Log `evidence/p1/format-check.log`.
3. `flutter analyze` -> 0, "No issues found". Log `evidence/p1/analyze.log`.
4. `flutter test` -> 0, 87 tests passed: 62 domain/service/repository (36
   domain, 9 services, 17 repository against real SQLite through
   `sqflite_common_ffi`), 20 widget, 5 render/golden. Logs
   `evidence/p1/test-all.log`, `evidence/p1/test-domain.log`,
   `evidence/p1/test-services.log`, `evidence/p1/test-data.log`,
   `evidence/p1/test-ui.log`, `evidence/p1/test-golden.log`.
5. `flutter test test/golden --update-goldens` -> 0, re-rendered the golden PNGs
   that the normal run then compares against. Only the new narrow rated editor
   render was added; the four earlier renders are byte-identical
   (`evidence/p1/render-hashes.txt`).
6. `flutter build apk --debug` -> 1, environment blocker described below.
   `./gradlew --version` -> 0 (Gradle 8.14, JVM 22.0.1), so Gradle itself runs.
7. `plutil -lint ios/Runner/Info.plist` -> 0 plus both purpose strings read back
   by `plutil -extract`. Log `evidence/p1/ios-permissions.log`.

Covered by the tests: close/reopen persistence of metadata and photo bytes;
separate copies sharing one barcode; copy clears rating/review/notes/photos and
leaves the source untouched; search including a literal `%`; medium filter;
newest-first order; delete; a missing asset reference rejected with no partial
write; update keeping identity and creation time; snapshot export/merge
idempotence, incoming-wins, absent-retained; merge rollback when one item is
invalid; corrupt file failing loudly and left byte-identical; barcode checksums;
rating, year and string bounds; image byte, pixel and non-image rejection;
add/edit/delete/search/filter flows; empty, no-results, error+retry and
unsaved-failure surfaces; the 20-photo cap; cancelled picker and picker failure;
320x568 at 1.6x text scale with no overflow exceptions.

## Correction cycle 1 (REVIEW-P1.md)

All six required groups are implemented; the deferred list was left for P2.

1. **iOS photo permissions.** `ios/Runner/Info.plist` now carries
   `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` with honest
   purpose strings (camera only when the user takes a photo; library only when
   the user chooses one; bytes stay on the device). Verified with `plutil -lint`
   and `plutil -extract` (`evidence/p1/ios-permissions.log`), so camera access
   can no longer terminate the app for a missing purpose string.
2. **Image safety before raster decode.** `lib/domain/image_inspector.dart` was
   rewritten to sniff the container, read dimensions from the PNG IHDR, JPEG
   start-of-frame and WebP VP8/VP8L/VP8X headers, apply the 5 MiB and 20 MP
   bounds, reject animation (PNG `acTL`, WebP VP8X animation flag), and only
   then decode one static frame whose dimensions must match the header.
   Regression tests: PNG and JPEG pixel bombs (including a truncated PNG whose
   header alone claims 50 000x50 000), a bounded valid image, animated PNG and
   animated WebP rejection, and a real WebP fixture accepted at 320x214
   (`test/fixtures/sample.webp`, provenance and SHA-256 in
   `evidence/p1/webp-fixture.txt`).
3. **Photo recovery and duplicate selection.** The controller notice is now
   pulled after the async recovery notifies instead of once during the first
   build, so it is actually shown. The editor validates, deduplicates and caps
   recovered photos and reports unreadable or skipped ones without a build-time
   exception; `_addPhoto` refuses a photo whose content-addressed id is already
   attached; `ImagePickerPhotoSource.recoverLostPhotos()` surfaces
   `LostDataResponse.exception` and file-read failures as `PhotoSourceFailure`.
   Tests: recovery success plus a bad image, the home recovery notice, repeated
   pick, and a picker-platform stub for the exception and empty-response paths.
4. **Async navigation lifetime.** `EditorScreen._save` and
   `DetailScreen._confirmDelete` now check `mounted` after their awaits and only
   report the outcome instead of popping whatever route is on top;
   `DetailScreen._viewPhoto` reports storage failures instead of throwing.
   Test: a delayed write that the user backs out of does not pop the home route,
   still records the copy and raises no exception.
5. **Immutable content-addressed models.** `MediaAsset` copies its bytes on
   construction and exposes only a read-only view; `MediaItem.photoAssetIds` and
   `LibrarySnapshot.items/assets` are unmodifiable copies. Write boundaries call
   `ImageInspector.verifyAsset`, which recomputes the SHA-256 and re-reads the
   MIME type and dimensions, so a forged or stale asset cannot enter the store.
   Tests: mutation attempts on assets, items and snapshots; forged asset id,
   lying MIME type and lying dimensions all rejected with zero rows written;
   merge with a forged asset rolls back completely.
6. **Small correctness and accessibility fixes.** `mergeSnapshot` now counts
   real insertions instead of summing row ids (two new assets -> 2, reimport ->
   0). Editor photo remove controls keep the small glyph but sit in a full 48dp
   target. `RatingInput` renders one correctly centred star per item, keeps
   half-star choices on the left/right halves of each 48dp target, and exposes
   slider semantics with increase/decrease actions and values.

The editor render was regenerated after the rating control change
(`evidence/p1/editor_390x844.png`); the other three renders are unchanged.

## Focused correction cycle 2 (REVIEW-P1-FOCUSED.md)

1. **Fail-closed PNG header walk.** `_readPngHeader` no longer stops silently at
   a chunk budget or treats "no acTL seen yet" as static. It walks chunks with a
   1024-chunk budget, returns an animated header the moment an `acTL` appears,
   and **refuses** a file that exceeds the budget instead of assuming it is a
   still (`too many header chunks to verify safely`). A malformed chunk length
   still falls through to the authoritative decoder stage, which rejects it.
2. **Decoder-authoritative metadata before any pixel work.** The inspector now
   uses the same decoder that would read pixels: `findDecoderForData(bytes)`,
   then `decoder.startDecode(bytes)` for the authoritative `DecodeInfo`. It
   verifies the decoder type matches the sniffed container, rejects
   animation (`PngInfo.isAnimated`/`numFrames`, `WebPInfo.hasAnimation`),
   applies the 20 MP and 5 MiB bounds to those authoritative dimensions, and
   rejects any disagreement with the cheap first-header read (`conflicting
   header information`). Only then does it decode pixels, and it calls
   `decoder.decode(bytes, frame: 0)`, so the default all-frames PNG path is
   never used. A post-decode check confirms the raster matches the
   authoritative metadata.
3. **WebP canvas versus bitstream.** For VP8X containers the inspector reads the
   canvas, short-circuits animation, then walks the bounded RIFF chunks for the
   embedded `VP8 `/`VP8L` frame. A bitstream larger than its canvas, or a canvas
   that does not match the decoder's dimensions, is refused before decode, and
   the canvas itself is bound-checked, so a canvas claiming a huge raster is
   rejected on metadata alone.
4. **Adversarial fixtures (all small).** `test/domain/image_safety_test.dart`
   now covers: 200 ancillary chunks followed by `acTL` (rejected as animated —
   the old 64-chunk guard would have missed it); a 1200-chunk pile (refused, not
   assumed static); a duplicate conflicting `IHDR` claiming 16x16 and another
   claiming 40 000x40 000 (both refused by the decoder metadata stage, no raster
   allocated); a WebP canvas of 4x4 wrapped around the real 320x214 bitstream
   (conflicting headers) and a 60 000x60 000 canvas (pixel bound); the truncated
   PNG whose header claims 50 000x50 000 (pixel bound); plus the valid JPEG, PNG
   and WebP fixture paths that must keep working. None of these fixtures is
   larger than a few hundred bytes, and the rejection happens without a decode.
5. **Rated narrow editor overflow.** `RatingInput` now measures its own width:
   when 5x48 dp of stars plus the value and clear action do not fit, the value
   and clear action move onto a second row instead of overflowing. Star targets
   and the clear action stay 48 dp with the same slider semantics. Regression:
   `a rated editor fits a narrow large-text phone` at 320x568 with 1.6x text,
   rating 4.0 -> 2.5 -> cleared, no overflow exceptions; render evidence
   `evidence/p1/editor_320x568_rated_scale1.6.png`.

## Rendered UI evidence (inspected)

Copied to `docs/agent-work/lyberry/evidence/p1/` and visually inspected:

- `home_390x844.png` - masthead with Oxanium wordmark and eyebrow, page heading,
  search field, medium tabs with the red active underline, two-column grid with
  real cover bytes, star ratings, and the Library / Scan / Settings bar.
- `detail_390x844.png` - cover, title, byline, rating, review, notes, photo
  strip, metadata rows, "Add another copy" and the delete action.
- `editor_390x844.png` - medium chips, labelled fields, barcode helper text,
  rating stars and the pinned "Add to collection" button.
- `home_320x568_scale1.6.png` - narrow plus large text: the eyebrow scales down
  instead of breaking words, tabs wrap, bar labels stay complete, no overflow.
- `editor_320x568_rated_scale1.6.png` - narrow large-text editor with a rating
  set: stars on one row, value and clear action below, nothing clipped.

This pass found and fixed three real defects:

- `lib/ui/widgets/bottom_bar.dart`: the bar overflowed by 2 px at 1.6x text. It
  now grows with the text scale, and labels shrink with `FittedBox` so they stay
  complete instead of ellipsizing.
- `lib/app.dart`: `AppShell` started the controller during build, which threw
  "setState during build" when the store failed to open. It now starts through a
  post-frame callback.
- `lib/ui/theme.dart`: button and chip label themes used bare `TextStyle`s and
  lost the platform text family, so those labels rendered with the fallback
  font. They now derive from the platform text theme.

## Android debug build blocker (reported, not worked around)

`flutter build apk --debug` fails during Gradle configuration after about 30 s.
The Gradle daemon log shows the Flutter Gradle plugin working in
`$FLUTTER_ROOT/packages/flutter_tools/gradle/.gradle`, which exists but is not
writable in this sandbox:

```
touch /Users/ghijs/development/flutter/packages/flutter_tools/gradle/.gradle/.codex_wtest
  -> Operation not permitted
```

`BRIEF-P1` authorises writes only to `<flutter>/bin/cache`, `~/.pub-cache` and
`~/.gradle`, and forbids requesting broader permissions, and the brief states
the final required build happens in P2. The build was therefore left as-is
instead of loosening the sandbox. Logs: `evidence/p1/build-apk.log`,
`evidence/p1/gradle-assemble-debug.log`,
`evidence/p1/gradle-assemble-debug-first-attempt.log`,
`evidence/p1/gradle-daemon-tail.log`.

Root has since granted this session write access to
`$FLUTTER_ROOT/packages/flutter_tools/gradle`. No build was retried after that
grant, because the review says the final Android build belongs to P2; the next
build attempt should be the first P2 check.

## Decisions taken inside the brief

- Widget and golden tests use an in-memory repository with the same observable
  semantics (`test/support/in_memory_repository.dart`), because `testWidgets`
  runs under fake async and cannot await real database I/O. Durable behaviour is
  covered by the real-SQLite repository suite instead.
- `sqlite3: ^2.6.0` is pinned as a dev dependency: the 3.x line ships a Dart
  native-assets hook that shells out to `dart compile kernel`, which needs the
  writable `~/.dart-tool` this sandbox denies. The app's on-device storage is
  `sqflite` and is unaffected.
- `image_picker` downscales to 2560 px at quality 90 so camera photos normally
  fit the 5 MiB asset bound instead of being rejected.
- `image_picker_platform_interface` is a dev dependency used only to stub the
  picker platform in `test/services/photo_source_test.dart`.
- Write boundaries decode each *new* asset once through
  `ImageInspector.verifyAsset` to prove the digest, MIME type and dimensions
  match the bytes. Stored blobs are never re-decoded, so the cost is bounded by
  the number and size of images actually being written.

## Known limits and risks for Astra

- No Android debug APK yet; the SDK write grant now exists, so P2 can attempt it
  directly. The iOS project is generated and configured (with purpose strings)
  but no simulator build was attempted.
- WebP now has a positive fixture test (official 320x214 VP8 sample) plus header
  and animation rejection paths; only WebP encoding is unsupported, which
  Lyberry never does.
- Photo capture, validation and Android lost-data recovery are covered by logic
  and widget tests plus a picker-platform stub, not by a physical device run.
- `README.md` is still the Flutter default; P2 owns launch, build, backup,
  provider-limit and privacy notes.
- Assets are never deleted, so the library file only grows. This is deliberate
  for v1 and documented in `sqlite_media_repository.dart`.
- The image inspector refuses (rather than guesses about) files with more than
  1024 header chunks or a container that contradicts its own metadata. That is
  the intended fail-closed trade-off; a legitimate but extremely chunk-heavy
  photo would need a deliberate limit review in P2.

## Deferred to P2 (acknowledged, not implemented here)

- `SnapshotCodec`: strict types, UTC canonical timestamps and all bounds before
  any base64 allocation, per-asset size before decode, combined size before
  decode, rejection of `schemaVersion` 1.0 loose equality, malformed `source`
  maps treated as errors, and equivalent encode-side limits plus a stable
  transaction snapshot.
- Bound `LibraryController`'s asset-future cache and decode grid thumbnails at
  display resolution for large libraries.
- Replace placeholder phase prose in the UI and the default `README.md`; change
  the editor notes helper from "never shared" to accurate local/private
  wording once backup export exists.

## P2 seams already in place

- `MediaRepository.exportSnapshot()` / `mergeSnapshot()` with `LibrarySnapshot`
  (`format: lyberry`, `schemaVersion: 1`) and `SnapshotCodec`: parses with
  bounds, rejects duplicate item/asset ids, verifies SHA-256 and image
  decodability, requires every referenced asset, and reports every problem in one
  `ValidationException` with zero partial changes. No backup UI yet.
- `MediaSource` provenance, stable `MediaType.wireValue`, canonical UTC
  timestamps and UUID v4 identities are ready for id-based merge semantics.
- `PhotoSource.recoverLostPhotos()` exists, `ScanScreen` is an honest phase-2
  placeholder, and `LibraryController.start()` is idempotent for scanner work.
- Provider rate-limit research lives in `PROVIDER-NOTES.md` (untouched).

## Next checkpoint

Astra reviews this report together with `evidence/p1/test-all.log` and the five
PNGs (hashes in `evidence/p1/render-hashes.txt`). The Android build is the first
P2 check now that the SDK write grant exists; nothing else is outstanding for
P1.
