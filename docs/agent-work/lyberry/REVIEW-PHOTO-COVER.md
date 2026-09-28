## Final resolution — accepted 2026-09-28

All source findings resolved and final targeted checks passed. Additional execution findings fixed: Future-error contract, 48dp density, route settling, persistent Scaffold fixture for race tests and waiting for the actual decoded rotated frame in goldens. Android gallery/crop/rotate/save/restart/cancel verified. No final full-suite run per user instruction. See ACCEPTANCE-PHOTO-COVER.md.

---

# PHOTO-COVER — Astra consolidated review, corrections required

Actual patch reviewed against photo-cover-pre-070. Correction baseline:
parent work/baselines/photo-cover-review1. Core crop pixel mapping and storage
choice are sound. Root ran focused Flutter tests: **39 passed / 1 failed**.
Initial full suite: **550 passed / 6 failed**. No APK or device QA yet.
Root owns all remaining Flutter/Gradle/device commands (external cache/socket
access works here); worker should not retry blocked commands or ask permissions.

## 1. Canonical image safety and EXIF ingest (P1)

Approved scope expansion: image_inspector.dart and its image-safety/ingest tests.
Honest orientation-5/6/7/8 JPEGs must ingest as original photos, not merely render
when bypassing MediaAsset. The installed JPEG decoder already bakes orientation
and clears the tag. Its JpegInfo is SOF/raw dimensions. image exposes public
img.decodeJpgExif(bytes); use its pre-decode orientation 5..8 to allow only the
expected exact transpose for JPEG in ImageInspector's final raster comparison.
Keep metadata dimensions returned by inspect consistent with prior raw/header
width/height to avoid changing existing stored-asset invariants. Keep all existing
header/decoder/bitstream agreement, animation, chunk, byte and pixel guards.

Remove CoverSourceGuard's parallel weaker validation: it lacks the existing
container/bitstream disagreement defenses (especially WebP canvas vs embedded
raster) and accepts any transpose without EXIF evidence. CoverRenderer should
reuse the corrected canonical ImageInspector path before raster work, or a small
shared validated-decode seam preserving every guard. Do not add a second header
parser or broadly relax PNG/WebP checks. Verify orientations 1..8 including
mirrors through ingest -> preview/crop -> asset/backup; retain negative image
safety fixtures including canvas/header disagreements and animation.

## 2. Completion/cancellation race and main-isolate decode (P1/P2)

CoverCropScreen._apply only checks mounted/disposed before Navigator.pop. During
the reverse transition after Cancel/back, the route can remain mounted while no
longer current: a finishing render could pop the underlying item editor. Guard
route/current/cancellation ownership before popping. Add a deferred render test
that completes during the back transition and proves the editor/draft survives.

ImageTransformService.deriveCover runs MediaAsset.fromBytes AFTER compute returns,
so the full final JPEG validation/decode/hash happens on the UI isolate. Move final
asset validation into the background render worker too (return a verified
MediaAsset, or equivalent safe seam); keep inline test worker on identical path.
The repository's verified-content optimization should still apply. No weakened
validation or raw unchecked trusted flags.

## 3. Photo-operation ownership and original retention (P2)

Editor._addPhoto checks _photoBusy but never sets it. Photo actions/removal and
lookup are also enabled while _saving, and remove remains enabled during loading.
Serialize photo operations with try/finally busy handling, guard the actual
handlers and disable conflicting capture/cover/remove/lookup/save controls during
save/load/transform. Recheck cap before adoption as necessary. Manual generation
must be claimed when the action begins, before async photo load/camera, so a late
auto cover cannot land while the user is choosing their manual source.

_openCoverCrop conflates asset presence with photo-list membership:
!_newAssets.containsKey(source.id) can skip re-adding an original previously
picked then removed within the draft, or a source identical to the derived
content-addressed asset. Dedupe photo references with _photoIds; retain the source
as a personal photo whenever absent and within cap, even if its asset already
exists. Preserve the unchanged bytes and independent cover/photo roles.
Tests: deferred capture prevents double actions/save, pending removed source
picked again as cover is retained, cancel/failed transform preserves old cover,
and manual intent wins even while waiting for the source bytes.

## 4. Actual failing test and meaningful assertions

photo_cover_flow_test.dart:197 expected stored photo count1, got0. Log also shows
Save tapped during a route transition (hit missed); fixed 20x20ms pumping is not
reliable route completion. Diagnose product vs harness and fix properly, then
assert crop route is gone/Save hit-testable and await actual stored outcome.
Do not simply weaken assertions. The current late-provider test accepts a null
cover with isNot assertions: require non-null expected derived asset/pixels and
prove Save executed. Avoid false-positive cancel/removal tests where Save is
missed. Fix reveal helper's wrong/offstage Scrollable hit warnings.

Exercise actual SnapshotCodec serialization/decode between SQLite export and
merge in photo_cover_backup_test.dart, including an EXIF original and derived
cover, then verify both after reopen. Existing test only merges an in-memory
snapshot and misses the portable import validation path.

## 5. Error and visual evidence

CropScreen._stage returns a permanent spinner when preview load has failed and
_preview is null. Render a stable error state with cancel and a retry action;
spinner only while loading. Ensure a failed apply can retry/cancel with old cover
unchanged. Cover photo action minimum36/shrinkWrap misses the 48dp target contract;
make its real hit area at least48 without losing compact style.

All three new golden tests use default MaterialApp theme, producing the wrong
visual language. Set buildLyberryTheme and the actual text-scaling path. Root
will generate and visually inspect the three crop renders after this correction.
Initial full failures: the one photo UI test; three not-yet-created crop goldens;
movie Settings version row (66px expected); finished editor golden (16.37% due
photo actions/scroll geometry, inspect intended content before accepting).
Root will update only those exact affected goldens after fixes. Historical
101 evidence PNGs must stay intact (root preservation script derives exact count).

## Handoff

One coherent correction bundle, including justified image safety scope above.
Flash owns code/test fixes, direct cached-Dart static/pixel checks and a concise
report delta. Root runs corrected focused suite (include canonical image safety),
required goldens, analysis/full suite, build and emulator QA. No repeat cache/adb
attempts, permissions, provider changes, live calls or docs-only follow-up phase.
