# Photo covers — accepted 0.7.0+9

2026-09-28. Astra reviewed the baseline-relative implementation and correction diffs; the native DeepSeek V4.1 Flash worker implemented and debugged the feature. Root executed Flutter/Gradle and device acceptance because worker cache/socket permissions blocked those commands. No live paid probe or provider/auth change was made.

## Behavior

Edit a copy, choose **Use as cover** beneath a personal photo, drag the crop corners, rotate left/right or reset, then apply and save the copy. Cover Camera/Library uses the same preview and retains the source as a personal photo. The derived cover is a separate asset; cancelling, removing a photo, or removing a cover preserves the other role. Decode, transform, final validation and hashing run in an isolate.

The canonical image inspector now accepts only the exact raster transpose explained by JPEG EXIF orientations 5–8. Existing byte/pixel/container/animation guards remain. Both schemas stay at 2; dependencies, credentials, lookup providers and platform permissions are unchanged.

## Verification

- **78 focused Flutter tests passed**, covering crop math, renderer/isolate path, photo-cover widgets, persistence/backup codec, canonical image safety and image ingestion. No hit-test warnings in the final run.
- **3 crop renders passed and were visually reviewed**, including the rotated frame and 320x568 at 1.6x text. Two directly affected editor/version goldens were refreshed. Historical 101 evidence PNGs match the baseline.
- Flash's cached Dart analysis/format checks passed (163 files before final test-only changes; final changed-test analysis/format also clean). **144 pixel/safety checks passed**.
- Fresh Gradle Android build succeeded in 22 seconds. APK 0.7.0+9, all three ABIs, ZIP integrity and SHA-256 verified.
- **No final full suite was run**, following the user's explicit usage constraint. Earlier failed development runs are retained as historical evidence and are not final validation.

## Android emulator acceptance

emulator-5554 was online. Installed over 0.4.1+6 with `adb install -r`; schema migrated 1 -> 2, the existing copy and all old column values were preserved, and Finished defaulted false. No uninstall or data clearing.

Using a clearly named QA copy and synthetic EXIF6 photo, exercised Android gallery selection, personal-photo Use as cover, orientation-correct preview, right rotation, corner resize, apply/save, restart, detail display, re-edit, left rotation and Cancel followed by Save. Original ingested photo remains 900x600; derived cover is 775x533 with a separate id. Both asset bytes and references remain unchanged after cancellation; Finished remains true. A first edge drag was intercepted by Android predictive Back, correctly cancelling the crop; dragging from inside the handle touch region succeeded. The picker recompresses selected JPEGs, so source preservation refers to the ingested personal photo.

Evidence: `evidence/photo-cover/device-upgrade.json`, `device-saved-cover.json`, device screenshots and `device-cleanup.json`. Raw database snapshots stay in the parent workspace's private scratch directory and are excluded from handoff. The QA copy was removed after verification; the normal deletion path retains its two small unreferenced synthetic assets. Existing copies are byte-for-byte unchanged against the post-upgrade rows.

## Handoff and limits

`deliverables/lyberry-0.7.0-debug.apk`, source ZIP, source manifest and adjacent SHA-256 files. APK SHA-256: `f79959b83f7c9a6c8aaee9fd354cba7c2e2c895db28d715babb93520599e9d93`. Older releases retained.

iOS runtime and live camera capture were not exercised in this run. Camera shares the tested crop path; backup encode/decode/merge was verified in focused tests rather than native file dialogs. No full-suite claim for this release.
