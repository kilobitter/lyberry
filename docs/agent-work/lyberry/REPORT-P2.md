# LYB-P2 completion report

STATUS: ready_for_review (P2, the REVIEW-P2 bundle and the focused
REVIEW-P2-FOCUSED storage/backup boundary fixes)
Task ID: LYB-P2
Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
Accepted baseline: `work/baselines/p1-accepted` (left untouched)
Date: 2026-09-24

## What P2 added

P1's local collection slice is now a complete, usable app: real scanning,
metadata lookup with candidate selection, portable backup with atomic merge,
Android-safe BLOB reads, bounded caches and finished user-facing flows.

1. **Scanning.** `lib/services/scan_coordinator.dart` turns repeated camera
   frames into at most one lookup (per-code debounce, camera stopped before the
   lookup, resume on return). `lib/ui/screens/scan_screen.dart` uses
   `mobile_scanner` (bundled ML Kit) with an injectable viewfinder seam for
   tests, a bounded preview so the manual fallback stays visible on short
   screens, app-lifecycle stop/start, a permission/unavailable state, and
   always-available manual ISBN/barcode entry. Nothing is auto-saved.
2. **Providers.** `lib/domain/identifier.dart` normalizes ISBN-10/13, EAN-8/13
   and UPC-A with checksum validation and equivalence (ISBN-10 <-> ISBN-13,
   UPC-A <-> zero-prefixed EAN-13). `lib/services/providers/` holds Open Library
   (edition-first year, never a work's `first_publish_year`), MusicBrainz
   (barcode query, format->medium inference, Cover Art Archive URL) and the free
   UPCitemdb trial adapter (category/title medium inference, quota mapping).
   `MetadataService` applies per-provider spacing, honours `Retry-After`/reset
   headers as cooldown without blocking the UI, caches completed lookups, keeps
   partial results, ranks exact matches first and never retries automatically.
3. **Candidate flow.** `lib/ui/screens/candidates_screen.dart` always shows
   candidates (a sole candidate included) with exact/possible labels, provider
   names, partial-failure notices, a no-match state with manual add, and a retry
   state for total failure. Choosing a candidate prefills the editor and records
   provenance; every field stays editable and nothing is written until Save.
4. **Backup.** `lib/services/backup_service.dart` exports one
   `.lyberry.json` file through the native save dialog and imports through a
   preview (`lib/ui/screens/merge_preview_screen.dart`) that states additions,
   replacements and the personal-data overwrite rule before a single atomic
   merge. `SnapshotCodec` is hardened for untrusted files (see below).
5. **Storage refinements.** `SqliteMediaRepository.getAsset` and
   `exportSnapshot` read asset metadata first and reconstruct payloads from
   bounded 256 KiB `substr` slices, so an Android cursor never holds a
   multi-megabyte row. New assets are verified against their bytes at the write
   boundary; already-stored assets are not re-decoded. Export reads inside one
   transaction and checks all export bounds first.
6. **Memory.** `LibraryController.asset` is a 32-entry LRU, and grid tiles,
   thumbnails and detail strips decode at their display width
   (`lib/ui/decoded_image_size.dart`) instead of full resolution.
7. **Cover downloads.** `lib/services/cover_downloader.dart` allows only
   allowlisted HTTPS hosts on port 443, rejects userinfo/IP-literal/private/
   loopback targets, re-validates every hop of at most 3 redirects, caps time and
   bytes, requires one static decodable image, caches successes, and returns
   `null` on any failure so a missing cover never blocks saving. Imports never
   make requests.
8. **Finished UI.** Settings now shows library size, backup export/import with
   outcomes and limits, provider limits, the User-Agent/contact status, privacy
   notes, font licence and version. Phase/debug placeholder prose is gone; the
   notes helper now says notes are included in an exported backup.
9. **Platform.** `android/app/src/main/AndroidManifest.xml` has INTERNET and
   CAMERA permissions with the camera feature optional, and the Android label is
   `Lyberry`. `ios/Runner/Info.plist` has accurate camera (scanning + photos) and
   photo-library purpose strings.

## Files added or changed

New domain/services:
`lib/domain/identifier.dart`, `lib/domain/lookup.dart`,
`lib/services/{transport,rate_limiter,lookup_cache,metadata_service,
cover_downloader,backup_service,scan_coordinator,user_agent}.dart`,
`lib/services/providers/{json,open_library_provider,musicbrainz_provider,
upcitemdb_provider}.dart`.

New UI/state:
`lib/app_services.dart`,
`lib/state/lookup_controller.dart`,
`lib/ui/decoded_image_size.dart`,
`lib/ui/screens/{candidates_screen,merge_preview_screen}.dart`.

Updated:
`lib/domain/{barcode,library_snapshot,media_item,media_asset,timestamps,
validation}.dart`,
`lib/data/{sqlite_media_repository,media_repository}.dart`,
`lib/state/{library_controller,item_draft}.dart`,
`lib/ui/screens/{scan_screen,settings_screen,editor_screen,detail_screen,
home_screen}.dart`,
`lib/ui/navigation.dart`, `lib/ui/widgets/{cover_tile,media_cover}.dart`,
`lib/main.dart`, `lib/app.dart`, `pubspec.yaml` (version 0.2.0+2 and the
mobile_scanner/file_picker/http dependencies), `README.md` (full rewrite),
`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`.

New tests (15 files under `test/`, 24 test files total):
`test/domain/{identifier_test,snapshot_hardening_test}.dart`,
`test/services/{providers_test,cover_downloader_test,scan_coordinator_test,
backup_service_test}.dart`,
`test/data/chunked_asset_test.dart`,
`test/ui/p2_flow_test.dart`,
`test/golden/p2_render_evidence_test.dart`,
`test/support/{fake_transport,fake_snapshot_io,stub_provider}.dart`.

## Verification (command, exit status, result)

All Flutter/Dart commands used `/Users/ghijs/development/flutter/bin/flutter`
with `FLUTTER_SUPPRESS_ANALYTICS=true` and `--no-version-check`; `dart format`
was run as `dart --suppress-analytics format`.

1. `flutter pub get` -> 0. Added `mobile_scanner 7.4.2`, `file_picker 13.1.0`,
   `http 1.6.0`.
2. `dart format --output=none --set-exit-if-changed lib test` -> 0
   (81 files, 0 changed). Log `evidence/p2/format-check.log`.
3. `flutter analyze` -> 0, "No issues found". Log `evidence/p2/analyze.log`.
4. `flutter test` -> 0, **196 tests passed**. Per-suite:
   `test/domain` 64, `test/services` 69, `test/data` 19, `test/ui` 33,
   `test/golden` 11. Logs `evidence/p2/test-all.log` and
   `evidence/p2/test-{domain,services,data,ui,golden}.log`.
5. `flutter build apk --debug` -> 0. `deliverables/lyberry-0.2.0-debug.apk`
   (172 MB debug build, all ABIs) with
   `deliverables/lyberry-0.2.0-debug.apk.sha256`
   (`34482a1185d183a9aa57b47c917eaec3b868977c984aa7403495670f7f370a19`),
   copied from `build/app/outputs/flutter-apk/app-debug.apk`. Log
   `evidence/p2/build-apk.log`.
6. `flutter build ios --simulator --debug` -> 1, "Application not configured for
   iOS": this machine has only the Xcode command line tools
   (`xcode-select -p` = `/Library/Developer/CommandLineTools`), and
   `flutter doctor` reports "Xcode installation is incomplete". Log
   `evidence/p2/build-ios-attempt.log`, summary
   `evidence/p2/flutter-doctor-summary.log`.
7. `dart run tool/live_provider_smoke.dart` -> 0. Real results in
   `evidence/p2/live-smoke.log`: MusicBrainz answered in 165 ms with one exact
   barcode match (year 1998), UPCitemdb in 431 ms with one exact match, and
   Open Library failed with `Failed host lookup: 'openlibrary.org'` because this
   environment's DNS does not resolve that host (`curl` reproduces it).

### Test coverage added in P2

- Identifier normalization and equivalence (ISBN-10/13, EAN-8/13, UPC-A), check
  digit helpers, rejection of bad checksums.
- Each provider adapter against fake transport fixtures: happy path, edition-year
  precedence over `first_publish_year`, missing edition fallback, no-match as an
  empty list, 429/503 with `Retry-After`, `TOO_FAST`/reset headers, malformed
  JSON, transport timeouts, fuzzy barcode marking, medium inference.
- `MetadataService`: exact-first ranking, partial failure retention, cache hits
  (providers not called twice), no caching of total failures, medium-hint
  filtering, per-provider spacing and cooldown.
- Cover policy: allowlist/subdomain rules, http/port/userinfo/unknown host
  rejection, loopback/private/link-local/IP-literal rejection, redirect
  following and refusal, redirect-hop cap, byte cap, non-image rejection and the
  cache.
- `ScanCoordinator`: debounce, distinct codes, camera stopped before lookup,
  invalid codes ignored, failure does not wedge the coordinator.
- Backup: export payload/counts/filename/cancel, preview counts, incoming-wins
  with older timestamps, absent-local retention, separate same-barcode copies,
  photo bytes round-trip, idempotent re-import, cancellation and malformed files
  leaving the library untouched.
- Snapshot hardening: byte cap before parsing, strict integer schema version
  (1.0/`'1'`/2/missing rejected), canonical UTC timestamps, malformed `source`
  blocks, per-image and combined-image caps, item/asset caps, duplicate ids,
  non-canonical base64, missing references, MIME mismatch and non-image payloads.
- Chunked BLOB: a real > 2 MiB PNG round-trips through `getAsset` and
  `exportSnapshot` with an identical SHA-256.
- UI flows: manual code -> candidates -> prefilled editor -> save; no-match with
  manual add; provider outage with retry and manual fallback; settings export ->
  import preview -> merge through the UI; cancelled import; malformed import
  error surfaced; narrow 320x568 at 1.6x text with no overflow.

## Correction cycle (REVIEW-P2.md)

All eight groups from the consolidated review are implemented as one bundle; the
pre-correction source is preserved by root at `work/baselines/p2-pre-correction`.

1. **Identifiers preserved, provider metadata accurate.** The normalized code
   travels with the chosen candidate (`ItemDraft.fromCandidate(..., barcode:)`
   from the scan screen), so a scan-to-match save keeps the code; the UI flow
   test asserts the stored barcode. Equivalence now drives matching, routing and
   caching through `NormalizedIdentifier.canonicalKey/matches`: ISBN-10 and
   ISBN-13 share one cache entry, MusicBrainz compares normalized barcodes,
   UPCitemdb marks equivalent EAN/UPC/ISBN values as exact, and requests use the
   canonical form. Open Library no longer displays `/authors/OL...A` ids as
   names: the edition's author comes from a matching search row or stays empty,
   and a failed search leg keeps the edition candidate with a warning
   (`ProviderLookupResult.warning`) that the service reports as a partial
   failure. UPCitemdb uses the provider's real description when present.
   Malformed shapes (`[]` roots, missing or wrong `docs`/`releases`/`items`,
   non-object rows) are typed failures or warnings, clearly distinct from a
   genuine empty list.
2. **Routing, quotas, bounded completion.** `MetadataService` routes ISBN ->
   Open Library first with the general fallback only when needed, CD/vinyl ->
   MusicBrainz first, DVD/Blu-ray/game -> UPCitemdb directly, and keeps partial
   candidates. Only a failure-free answer is cached, so a retry can reach the
   provider that failed. Throttling sits at the HTTP request boundary
   (`ProviderRateLimiter.guard()` inside each adapter, so Open Library's edition
   and search legs are two spaced requests); a wait longer than ~1.2 s becomes an
   immediate typed `cooldown` failure instead of a long spinner, and only
   quota/cooldown answers penalise a provider. `X-RateLimit-Reset` is parsed as
   an absolute Unix epoch (stale -> zero, implausible -> one hour) and
   `Retry-After` supports delta-seconds and RFC HTTP dates against an injected
   clock.
3. **One camera lifecycle owner, guarded manual path.** `ScanCamera`
   (`lib/services/scan_camera.dart`) wraps
   `MobileScannerController(autoStart: false)` and reports the plugin's real
   running state; the plugin's own lifecycle handling is off, so `ScanScreen` is
   the single owner and starts only when the app is resumed *and* the route is
   visible, stopping on suspension, navigation to candidates/editor and
   disposal. Manual submissions use the same `ScanCoordinator.submit` in-flight
   guard as camera detections. The manual helper text no longer claims offline
   lookup, and "Add a copy by hand instead" is always available.
4. **Export bounds and off-isolate work.** Export fails before the file picker
   opens when the payload exceeds the cap, and `BackupExportResult.byteLength` is
   the real UTF-8 byte count. This first pass used a size estimate plus a
   `MediaAsset.verified` marker; the focused follow-up below replaced both with
   an exact bounded encoder and the closed `MediaAsset.fromBytes` factory, which
   is the design that ships.
5. **Back during an applying merge.** `MergePreviewScreen` is wrapped in
   `PopScope(canPop: !_busy)`, so a back gesture cannot detach a screen whose
   transaction is still running, and a second confirmation cannot start another
   merge. `BackupService.lastAppliedResult` lets Settings report the real outcome
   if the route disappears anyway. The delayed-merge widget test covers back,
   double-confirm, the reported result and the refreshed library.
6. **Full HTTP deadline, contained cover failures.** `IoHttpTransport` uses a
   real `HttpClient` with one overall deadline covering headers *and* body,
   force-closes the socket on deadline, size overflow or completion, and
   normalises streamed network errors. Local-socket tests cover a trickling body,
   an oversized body and a mid-body connection drop. `CoverDownloader` catches
   every unexpected transport/redirect error and degrades to the medium
   placeholder; the allowlist policy is unchanged (only `archive.org`
   subdomains are broadened).
7. **Stale covers cannot win.** The editor tracks a cover request sequence and a
   choice generation, bumped by manual cover changes, removal, a new lookup and
   disposal, so an out-of-order download is discarded. Widget tests cover a slow
   cover losing to a newer choice and to an explicit removal; saving with no
   cover still works.
8. **User-facing wording.** Settings no longer mentions SQLite, `--dart-define`,
   User-Agent values or host allowlists. It explains local storage, that lookups
   need network access with free public sources that can be temporarily
   unavailable, ordinary backup limits, and privacy in two clear cases:
   automatic lookup requests carry only the code, while an explicit export
   contains notes and photos and should be kept somewhere trusted.
   Maintainer/contact and allowlist details live in `README.md`.

Correction-cycle files: `lib/services/{transport,rate_limiter,metadata_service,
cover_downloader,backup_service,scan_camera}.dart`, `lib/services/providers/*`,
`lib/domain/{lookup,identifier,media_asset,library_snapshot,validation}.dart`,
`lib/data/sqlite_media_repository.dart`,
`lib/ui/screens/{scan_screen,settings_screen,editor_screen,merge_preview_screen}.dart`,
`tool/live_provider_smoke.dart`, new/updated tests
(`test/services/{routing_and_limits_test,transport_test}.dart`,
`test/support/fake_scan_camera.dart`, plus provider, snapshot, UI and golden
additions) and the regenerated settings renders. Obsolete failure renders from
earlier golden runs were removed from `test/golden/`.

## Focused storage/backup cycle (REVIEW-P2-FOCUSED.md)

1. **Closed `MediaAsset` validation boundary.** The public
   `MediaAsset.verified(...)` constructor is gone and the class is `final`.
   There are exactly two construction paths now: the plain public constructor,
   which describes bytes from elsewhere and is never marked verified, and the
   public factory `MediaAsset.fromBytes(bytes, limits:, field:)`, which derives
   the SHA-256 id, MIME type and dimensions itself and is the only path that sets
   the verified marker (through a private constructor). `ImageIngest` uses that
   factory, `SnapshotCodec` uses it and then compares the claimed imported id and
   MIME type against the derived facts, and database reads use the plain
   constructor because browsing must not decode every stored raster again.
   Anything not marked verified is fully checked - digest, MIME type,
   dimensions, animation and bounds - before a write, and the forged-id,
   lying-MIME, lying-dimension and rollback repository tests still prove it.
2. **Exact bounded encoding, off the UI isolate.** `SnapshotCodec.encode` no
   longer estimates: it escapes each item and asset with the real JSON encoder
   and counts the exact UTF-8 bytes as it appends, aborting the moment the output
   would exceed the file cap. Valid under-limit payloads are therefore never
   rejected (ASCII metadata no longer costs four bytes per character) and
   escaped control characters and nested `source` fields are counted exactly.
   The payload is compact JSON; the item, asset, per-image and combined-image
   caps are unchanged. `BackupService.export` performs that encoding on a worker
   isolate, capturing only the snapshot and the limits.
3. **Isolate contracts plus a real-SQLite regression.** Both `_encode` and
   `_decode` capture only sendable locals (`snapshot`/`contents` and `limits`)
   instead of `this`, so the worker never sees the repository, the platform file
   picker or the clock. `test/data/backup_isolate_test.dart` uses the **default
   isolate-enabled** `BackupService` with real SQLite repositories and
   round-trips an item, its notes, rating and photo bytes through export and
   import. Existing `useIsolate: false` fakes remain for widget-speed tests; the
   flag was renamed from `decodeInIsolate` because it now covers both directions.

Affected tests: `test/domain/snapshot_hardening_test.dart` (under-cap ASCII,
exact-cap boundary, escaped control characters, nested source fields, multibyte
round-trip, picker never opens on failure), `test/data/backup_isolate_test.dart`
(real SQLite with default isolates) and the unchanged forged-asset/rollback
repository tests plus `test/data/chunked_asset_test.dart`.

## Rendered evidence (inspected)

All PNGs are in `docs/agent-work/lyberry/evidence/p2/` and were generated by the
golden tests.

New P2 renders:

- `p2_candidates_390x844.png` - matches list with the code, result count, the
  "nothing is saved" line, exact/possible labels, provider names and the
  manual-add action.
- `p2_candidates_320x568_scale1.6.png` - the same list at 320x568 with 1.6x text;
  cards grow instead of clipping and the layout stays scrollable.
- `p2_merge_preview_390x844.png` - file name, size/copy/image counts, add and
  replace counts, the overwrite wording, Merge and Cancel.
- `p2_merge_preview_320x568_scale1.6.png` - the same preview on a narrow
  large-text phone; counts, warning and actions stay readable with no overflow.
- `p2_settings_390x844.png` - library size, backup buttons, limits, provider
  rates, contact/User-Agent status, privacy and licence sections.
- `p2_settings_320x568_scale1.6.png` - settings at 320x568 with 1.6x text; every
  section scrolls with no clipped text.

P1 renders re-generated after the P2 image-decode change (same Redline layout):
`home_390x844.png`, `home_320x568_scale1.6.png`, `detail_390x844.png`,
`editor_390x844.png`, `editor_320x568_rated_scale1.6.png`.

## Android build and device status

- **Android debug APK: built.** The two P1 blockers are resolved with the
  parent's grants: the Flutter tool's Gradle project cache and the debug keystore
  directory (`~/.android`) are writable, and the nested `flutter assemble` step
  needs `FLUTTER_SUPPRESS_ANALYTICS=true` in the environment (without it the
  telemetry write to `~/.dart-tool` masks the real build error). Reproduce with:
  `FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true flutter
  --no-version-check build apk --debug`.
- **Android runtime device: none available.** `adb devices` shows only
  `emulator-5562 offline`. One bounded headless attempt with
  `emulator -avd Pixel_8a -no-window -no-audio -no-boot-anim
  -crash-report-mode disabled -gpu swiftshader_indirect` started the emulator
  process (crash reporting disabled, system image found) but no device came
  online within the 80 s window while the pre-existing offline instance held the
  default port. Logs `evidence/p2/emulator-attempt.log`,
  `evidence/p2/adb-devices.log`. No further launches were attempted.
- **iOS: blocked by environment.** `flutter build ios --simulator --debug` ->
  "Application not configured for iOS"; `flutter doctor` says the Xcode
  installation is incomplete (only `/Library/Developer/CommandLineTools`), and
  `xcrun simctl` is unavailable. The iOS project, purpose strings and Podfile-less
  plugin wiring are in place, but no iOS build or runtime claim is made.

## Provider validation: fixtures vs live

- Automated validation is fixture-based: every adapter is exercised through
  `FakeHttpTransport` with recorded response shapes, including malformed,
  no-match, quota and HTTP-date paths. The normal test suite makes no network
  requests.
- A host-side opt-in smoke (`dart run tool/live_provider_smoke.dart`) then
  exercised the **real** adapters and transport with three public sample codes
  and no personal data, respecting the same throttling as the app:
  MusicBrainz returned one exact barcode match in 165 ms (release year 1998) and
  UPCitemdb one exact code match in 431 ms. Open Library's host does not resolve
  in this environment (`Failed host lookup: 'openlibrary.org'`; `curl` fails the
  same way), so its adapter remains fixture-validated only.
- Raw evidence: `evidence/p2/live-smoke.log`. Four public requests were made in
  total (two for Open Library's edition + search legs, one each for the others),
  with no paid keys and no automatic retries.
- Rate limits are implemented from `PROVIDER-NOTES.md` (Open Library and
  MusicBrainz ~1 rps, UPCitemdb one call per 10 s inside 100/day) and are
  enforced per provider; `LYBERRY_CONTACT` remains a release prerequisite for
  MusicBrainz etiquette.

## Limits and blockers

- No real device or emulator run, so camera scanning, gallery picking, file
  pick/save dialogs and iOS runtime behaviour are covered by tests and
  configuration review only. A simulator build does not prove camera behaviour,
  and none was possible here.
- The `flutter test` VM has no outbound network in this sandbox, which is why the
  live provider check runs as the host-side `tool/live_provider_smoke.dart`
  script; it uses the same adapters, transport and throttling. Open Library's
  host does not resolve in this environment at all (DNS), so only MusicBrainz
  and UPCitemdb have live evidence.
- Android debug APK is 172 MB because debug builds include every ABI and no
  shrinking; a release build is out of scope for this phase.
- Unreferenced image rows are retained by design, so the library file only grows.
- The image inspector refuses (rather than guesses about) files with more than
  1024 header chunks or self-contradictory container metadata.
- Live provider behaviour (quota exhaustion, response drift) can only be
  confirmed with real network calls on a device.

## Deferred (explicitly not in P2)

Nothing from `BRIEF-P2.md` remains unimplemented. Items intentionally left for
later: release signing/store packaging, analytics-free telemetry is already the
default, multi-provider live smoke tests on hardware, thumbnail disk cache, and
any additional provider (for example Discogs) - none of which the brief asked
for.

## Next checkpoint

Astra reviews this report with `evidence/p2/test-all.log`, the renders and the
APK in `deliverables/`. The focused storage/backup cycle is complete and the
final design is documented above. MusicBrainz and UPCitemdb have live evidence;
the remaining gaps are hardware verification (camera scan, gallery, file
dialogs, iOS simulator/device) and a live Open Library check, which need a
usable device, a full Xcode installation and a network that resolves
`openlibrary.org`.
