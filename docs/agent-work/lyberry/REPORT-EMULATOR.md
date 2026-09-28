# Emulator and on-device app test report

STATUS: complete - Lyberry installed, launched and exercised on the live emulator
Date: 2026-09-24 (third pass: barcode helper wrap correction; earlier passes:
corrected copy, scan navigation, manual add, restart persistence)
Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`

## Headline correction

Earlier evidence in this report says "emulator blocked". That was too broad and
is corrected here: **only the sandboxed command-line launch is blocked**. Root
launched `Pixel_8a` through Android Studio's Device Manager outside the command
sandbox, and the emulator is online. The agent's adb CLI then worked normally
against it, and the app test below was performed on that live device.

## Emulator availability, both paths

### IDE / unsandboxed launch: works

Root's Device Manager run shows `Pixel 8a API 37 emulator-5554` online with the
Android home screen. The agent confirms the same device over adb:

```
adb devices -l
  emulator-5554   device product:sdk_gphone16k_arm64 model:sdk_gphone16k_arm64
                  device:emu64a16k transport_id:555
  emulator-5562   offline transport_id:561      (pre-existing, untouched)
adb -s emulator-5554 get-state                  -> device
adb -s emulator-5554 shell getprop sys.boot_completed -> 1
```

So the AVD, system image and hypervisor are fine; the emulator runs.

### Sandboxed command-line launch (agent): blocked

One bounded headless attempt was made before root's launch, with
`-avd Pixel_8a -port 5580 -read-only -no-snapshot-load -no-snapshot-save
-no-window -no-audio -no-boot-anim -gpu swiftshader_indirect
-crash-report-mode disabled` (exact command: `evidence/emulator/launch-command.txt`).
For 120 s `adb -s emulator-5580 get-state` returned
`error: device 'emulator-5580' not found`, then the process had exited
(`evidence/emulator/wait-loop-transcript.log`). The emulator log stops at
`Found systemPath ...` and macOS recorded:

```
qemu-system-aarch64-headless-2026-09-24-093335.ips (pid 63470, parent zsh)
  exception:   EXC_BAD_INSTRUCTION / SIGILL
  codes:       0x1, 0x00000000d53b0029
  termination: Illegal instruction: 4
  top frames:  qemu-system-aarch64-headless+4598068 -> dyld+314928 -> ...
```

`0xd53b0029` is the ARM64 `MRS x9, CTR_EL0` CPU-feature read, executed inside
qemu's dyld-time startup before any guest code. The same shell also cannot run
the host probes qemu uses (`sysctl hw.optional.arm64`, `kern.hv_support`,
`hw.ncpu` all return "Operation not permitted"), cannot create the Crashpad
child port (`bootstrap_check_in ... Permission denied (1100)`), and this turn
cannot write to `~/.android` or the AVD directory (`AVD_WRITE_DENIED`). Full
detail: `evidence/emulator/env-diagnostics.log` and
`evidence/emulator/crash-report-summary.txt`. None of this applies to the IDE
launch, which is unsandboxed.

## Real app test on `emulator-5554`

All steps via adb only; no code changes, no rebuild, no UI manipulation beyond
launching the activity. Full transcript: `evidence/emulator/app-test-summary.txt`.

| Step | Command | Result |
| --- | --- | --- |
| Install | `adb -s emulator-5554 install -r -t deliverables/lyberry-0.2.0-debug.apk` | `Performing Streamed Install` / `Success`, exit 0 |
| Package | `adb -s emulator-5554 shell dumpsys package app.lyberry.lyberry` | `versionName=0.2.0`, `versionCode=2`, `minSdk=24`, `targetSdk=36`, installed 09:40:48 |
| Launch | `adb -s emulator-5554 shell am start -n app.lyberry.lyberry/.MainActivity` | `Starting: Intent { cmp=app.lyberry.lyberry/.MainActivity }`, exit 0 |
| Process | `adb -s emulator-5554 shell pidof app.lyberry.lyberry` | `5210` (same pid on the 25 s re-check) |
| Foreground | `dumpsys activity activities` | `topResumedActivity=... app.lyberry.lyberry/.MainActivity` |
| Focus | `dumpsys window` | `mCurrentFocus=Window{... app.lyberry.lyberry/app.lyberry.lyberry.MainActivity}` |
| Drawn | logcat | `Displayed .../.MainActivity for user 0: +6s430ms`, `Fully drawn ...` |
| Stability | 600 logcat lines after a 15 s wait | 0 matches for `FATAL EXCEPTION`, `AndroidRuntime.*FATAL`, `ANR in app.lyberry` |
| Screenshot | `adb -s emulator-5554 exec-out screencap -p > lyberry-home.png` | 1080x2400 PNG, 132 537 bytes, exit 0 |

The APK used in the first pass was `deliverables/lyberry-0.2.0-debug.apk`,
SHA-256 `34482a1185d183a9aa57b47c917eaec3b868977c984aa7403495670f7f370a19`.
That build was superseded twice: the second pass rebuilt it as SHA-256
`149f500ea213da9b43bb92d4260a7f7d58081e90e70315f624e869c8f653dfd5`, and the
third pass (helper wrap fix) rebuilt it again as SHA-256
`7b7fbaf0f4c8e6abb4510eec867f13e8c7836d423aec09e8a95c39e7516fe353`. The hash
alongside the APK in `deliverables/` matches the third build.

`evidence/emulator/lyberry-home.png` was inspected: it shows the Lyberry
masthead, "Your collection / 0 items", the search field, the medium tabs, the
"RECENTLY ADDED / 0 items" empty state with the red "Add a copy" action, and the
Library / Scan / Settings bar. First launch is genuinely empty, as designed.

## Bounded fix cycle: corrected copy, scan navigation, manual add, persistence

The first pass found user-facing phase prose in the empty state
(`lib/ui/screens/home_screen.dart`). A follow-up bundle authorized a one-line
copy change plus a live re-verification, which is recorded here.

### Change

- `lib/ui/screens/home_screen.dart` - the empty-state secondary action now reads
  **"Scan a barcode"** instead of "Scanning arrives in phase 2"; `onPressed`
  still calls `openScan(context)`; the action now has a stable
  `Key('home-empty-scan')` for its widget test.
- `test/ui/p2_flow_test.dart` - a focused widget test
  `the empty state points at the real scanner, not phase prose` asserts the
  new label, asserts the old string is gone, taps the action and checks that the
  scanner screen (`Key('scan-manual-field')`) opens with no exception.

The scan screen's camera-denied fallback is pre-existing P2 code
(`lib/ui/screens/scan_screen.dart:216` after the third-pass edit); it was
rendered and confirmed here, not modified in the second pass.

### Checks run

| Check | Command | Result |
| --- | --- | --- |
| Focused widget test | `flutter test test/ui/p2_flow_test.dart --plain-name 'the empty state points at the real scanner, not phase prose'` | `+1: All tests passed!` |
| Full suite | `flutter test` | `00:08 +197: All tests passed!` |
| Analyzer | `flutter analyze` | `No issues found! (ran in 8.3s)` |
| Formatter | `dart format --output=none --set-exit-if-changed lib test` | `Formatted 86 files (0 changed)`; process exit is 1 only because the sandbox blocks the telemetry write to `~/.dart-tool/dart-flutter-telemetry-session.json` (`Operation not permitted`), not because of formatting |
| Rebuild | `flutter build apk --debug` (same command as the accepted P2 build, whose log is `evidence/p2/build-apk.log`) | `deliverables/lyberry-0.2.0-debug.apk` mtime `2026-09-24 09:48` (after the 09:45 source edit), SHA-256 `149f500ea213da9b43bb92d4260a7f7d58081e90e70315f624e869c8f653dfd5`, 172 224 791 bytes; the raw build log for this second build was not saved into `evidence/emulator/`, so the artifact is evidenced by its mtime, hash and the installed-on-device behaviour |
| Install | `adb -s emulator-5554 install -r -t deliverables/lyberry-0.2.0-debug.apk` | `Performing Streamed Install` / `Success`, exit 0, `lastUpdateTime=2026-09-24 09:48:36` |

### Live verification on `emulator-5554` (adb only)

1. **Corrected copy live.** `uiautomator dump` of the empty state lists a node
   with `content-desc="Scan a barcode"` at `[373,1680][707,1806]`. Screenshot
   `textfix-01-empty-state.png`; semantics dump
   `ui-home-empty-semantics.xml`.
2. **Scan navigation (no camera capture).** Tapping that action at `(540,1743)`
   opened the Scan route: `dumpsys window` reported `mCurrentFocus` back on
   `app.lyberry.lyberry/.MainActivity`, camera stayed `granted=false`, and the
   Android permission dialog (`GrantPermissionsActivity`) came up for
   `android.permission.CAMERA`. Denying it (`Don't allow`) set
   `USER_SET|USER_FIXED` and reopening Scan raised **no further dialog**
   (`logcat | grep -c GrantPermissionsActivity` delta = 0) and no crash; the
   route rendered the graceful fallback instead. Its semantics read
   `Camera access is off\nType the ISBN or barcode below instead.` with the
   manual code field, `Look up` and `Add a copy by hand instead` present.
   Screenshot `scan-06-permission-denied-screen.png`. No barcode was decoded and
   no camera frame was captured; the emulator's virtual camera was never used.
3. **Manual add through the UI.** From the Scan fallback, `Add a copy by hand
   instead` `(540,1878)` opened the "New copy" editor. Filled via adb input:
   Title `Emulator Smoke Test Book`, Creator `Flash QA`, Year `2026`, and a
   4.5-star rating (the tap landed on the 4.5 hit target; semantics reported
   `4.5, Rating\n4.5`). Saved with `Add to collection`. Screenshots
   `manualadd-01-editor-open.png`, `manualadd-02-editor-filled.png`.
4. **Home count.** Returning to the Library tab showed `1 item` twice (header
   and `RECENTLY ADDED`) plus one cover tile whose semantics read
   `Emulator Smoke Test Book, Flash QA | Book ... Rated 4.5 out of 5`.
   Screenshot `manualadd-04-home-one-item.png`.
5. **Persistence across process restart.** `am force-stop` followed by a cold
   `am start -W` (`LaunchState: COLD`, `TotalTime: 3069`) brought back the same
   library: `1 item`, the same tile and rating, new pid, no fatal log line.
   Screenshot `manualadd-05-after-process-restart.png`, semantics
   `ui-after-restart-semantics.xml`, log check `fatal_or_anr_lines=0`.
6. **Storage proof.** `run-as app.lyberry.lyberry` shows
   `databases/lyberry.db` (40 960 bytes, written 09:53). The DB was pulled and
   queried: one row, `medium=book`, `title=Emulator Smoke Test Book`,
   `creator=Flash QA`, `year=2026`, `rating=4.5`. Raw log
   `manualadd-summary.txt`, copy `pulled-lyberry.db`.

### Behaviour note for the P2 owner (not a defect claim)

The editor was opened from the Scan route, so `Add to collection` popped back to
the Scan screen rather than the Library tab; pressing Back then showed the new
item. Whether a save should always return the user to the collection is a
navigation decision for the coordinator, not something this bundle changed.

## Focused correction: barcode helper truncation (third pass)

Astra's review of `scan-06-permission-denied-screen.png` found the helper under
the ISBN/barcode field ellipsised to `Addi...`. The helper is one long sentence
and `InputDecorator` clamps it to a single ellipsised line unless
`helperMaxLines` is set, so the copy was correct but clipped.

### Change

- `lib/ui/screens/scan_screen.dart` - the manual field's `InputDecoration` now
  sets `helperMaxLines: 4`, so the sentence wraps to as many lines as it needs
  (two on the Pixel 8a emulator, four at 320x568 with 1.6x text) instead of
  being cut. Hint, style, keys, `Look up` behaviour and the camera-denied
  fallback are unchanged.
- `test/support/fake_scan_camera.dart` - `FakeScanCamera` can report a
  `previewError`, rendered through the same `onError` seam as
  `MobileScanner.errorBuilder`, so tests can render the real
  "Camera access is off" fallback without hardware.
- `test/ui/p2_flow_test.dart` - new focused test
  `the barcode helper wraps fully instead of being truncated`: at 320x568 with
  1.6x text it renders the denied-camera scan screen, then asserts the helper's
  `RenderParagraph` has `didExceedMaxLines == false` and is taller than a single
  clamped line.
- `test/golden/p2_render_evidence_test.dart` - two new renders of the denied
  scan screen, `goldens/p2_scan_permission_denied_390x844.png` and
  `goldens/p2_scan_permission_denied_320x568_scale1.6.png`, copied into
  `evidence/p2/`.
- `test/ui/p2_flow_test.dart` - the pre-existing narrow/large-text flow test now
  scrolls the lazily built `Look up` button into view before tapping, using the
  file's existing `reveal` helper: with the helper no longer clipped, the button
  sits below the first 320x568 viewport. No assertion was weakened.

### Checks run

| Check | Command | Result |
| --- | --- | --- |
| Focused widget test | `flutter test test/ui/p2_flow_test.dart --plain-name 'the barcode helper wraps fully instead of being truncated'` | `+1: All tests passed!` |
| Golden renders | `flutter test --update-goldens test/golden/p2_render_evidence_test.dart --plain-name 'scan fallback'`, then `flutter test test/golden/p2_render_evidence_test.dart` | `+2` new goldens written, then all 8 golden tests pass with no update |
| Full suite | `flutter test` | `00:08 +200: All tests passed!` |
| Analyzer | `flutter analyze` | `No issues found! (ran in 9.8s)` |
| Formatter | `dart format --output=none --set-exit-if-changed lib test` | `Formatted 86 files (0 changed)` (same sandbox telemetry exit artifact as above) |
| Rebuild | `flutter build apk --debug` with `FLUTTER_SUPPRESS_ANALYTICS=true` | exit 0, `Built build/app/outputs/flutter-apk/app-debug.apk` in 9.6 s; log `evidence/emulator/build-apk-helperfix.log`; published hash `7b7fbaf0f4c8e6abb4510eec867f13e8c7836d423aec09e8a95c39e7516fe353` (172 224 791 bytes) |
| Install | `adb -s emulator-5554 install -r -t deliverables/lyberry-0.2.0-debug.apk` | `Performing Streamed Install` / `Success`, `lastUpdateTime=2026-09-24 10:07:14`; log `evidence/emulator/adb-install-helperfix.log` |

### Live verification on `emulator-5554`

1. Launched the rebuilt app (`am start -W`, `TotalTime: 2986`) and opened the
   Scan tab from the bottom bar. Camera permission was still
   `granted=false, USER_SET|USER_FIXED`, so no dialog appeared and the denied
   fallback rendered.
2. `uiautomator` now reports the helper node at `[100,1611][980,1705]`, i.e.
   **94 px tall across two lines**, where the same node measured 47 px (one
   clipped line) before the fix. Screenshot `scan-07-helper-wraps.png` shows the
   complete sentence: "Looking up a code needs a network connection." /
   "Adding a copy by hand always works."
3. `Look up` and `Add a copy by hand instead` remain below it and unchanged;
   the emulator's default font scale makes this the same large-text case Astra
   flagged. `logcat` after launch: `fatal_or_anr_lines=0`.
4. Reinstall kept the app data: the Library still shows `1 item` with
   `Emulator Smoke Test Book ... Rated 4.5 out of 5`, and the pulled database
   still has exactly one row (`scan-08-library-after-install.png`,
   `pulled-lyberry-after-helperfix.db`).

### Limit

The helper is capped at four lines. Every size the app targets (320x568 at 1.6x
text and up) fits well inside that cap, but a narrower window or a text scale
above roughly 1.6x on a very short screen could still ellipsise the last line;
the copy is unchanged and no other behaviour depends on the cap.

## What was not tested

Still not exercised on any device:

- real camera barcode decoding (the emulator's virtual camera was not used; only
  the permission-denied path was driven),
- the photo/gallery picker and file dialogs (gallery import, export/backup
  `file_picker` and `share_plus` flows),
- the metadata lookup network path from the device (`Look up` was deliberately
  not tapped; provider behaviour is covered by host-side tests and the accepted
  low-volume live smoke),
- multiple copies/photos, detail editing, merge and settings flows on-device.

Nothing above should be claimed as device-verified from this run.

## Practical paths forward

1. **Proven path for agent testing:** start the emulator from Android Studio's
   Device Manager (unsandboxed) as root did, then drive the app with adb from the
   agent exactly as in this report.
2. **Real device over adb** remains the only meaningful way to validate the
   camera, gallery and file pickers.
3. An agent-launched command-line emulator would need write access to
   `~/.android` plus Mach/bootstrap port access and host probe permission - the
   same restrictions root already identified as not grantable through the agent
   sandbox, which is why path 1 is the working arrangement.

## Evidence index (`docs/agent-work/lyberry/evidence/emulator/`)

On-device app test:

- `app-test-summary.txt` - commands, results, package/version, finding
- `adb-install.log`, `adb-launch.log` - raw install and launch output
- `logcat-after-launch.txt`, `logcat-stability-recheck.txt` - bounded logcat
- `lyberry-home.png` - screenshot of the running app (1080x2400)

Second pass (corrected copy, scan navigation, manual add, restart persistence):

- `manualadd-summary.txt` - consolidated command/result log (device, package,
  semantics excerpts, SQLite query, crash count, APK hash)
- `adb-install-textfix.log` - install output of the rebuilt APK
- `textfix-01-empty-state.png`, `textfix-02-home-before-scan.png`,
  `textfix-03-home-clean.png` - corrected empty state and home
- `scan-00-camera-permission-dialog.png`, `scan-01-opened.png`,
  `scan-02-screen-camera-denied.png`, `scan-03-screen-camera-denied.png`,
  `scan-04-after-force-stop-dialog-dismissed.png`,
  `scan-05-permission-denied-fallback.png`,
  `scan-06-permission-denied-screen.png` - scan route and permission handling
- `manualadd-01-editor-open.png`, `manualadd-02-editor-filled.png`,
  `manualadd-04-home-one-item.png`,
  `manualadd-05-after-process-restart.png` - manual add and persistence
- `ui-home-empty-semantics.xml`, `ui-scan-semantics.xml`,
  `ui-editor-semantics.xml`, `ui-editor-filled-semantics.xml`,
  `ui-home-one-item-semantics.xml`, `ui-after-restart-semantics.xml` - raw
  `uiautomator dump` output used for the assertions above
- `pulled-lyberry.db` - SQLite database copied off the device
- `emulator-final-state.png` - final state as handed back to root: `Lyberry`
  foreground on `emulator-5554` (pid 9622) showing the persisted 1-item library

Third pass (barcode helper wrap correction):

- `build-apk-helperfix.log`, `adb-install-helperfix.log` - build and install of
  the third APK (`7b7fbaf0...`)
- `scan-07-helper-wraps.png` - denied-camera Scan screen with the full two-line
  helper, captured at the emulator's large text scale
- `ui-scan-helperfix-semantics.xml` - semantics for that screen (helper node
  94 px tall across two lines, 47 px before the fix)
- `scan-08-library-after-install.png`, `ui-after-helperfix-install-semantics.xml`,
  `pulled-lyberry-after-helperfix.db` - library still holding the manual-add
  row after the reinstall
- `docs/agent-work/lyberry/evidence/p2/scan_permission_denied_390x844.png`,
  `.../scan_permission_denied_320x568_scale1.6.png` - widget renders of the same
  fallback at 1.0x and at 320x568 with 1.6x text (copies of the goldens)

Sandboxed command-line launch attempt (kept for scope accuracy):

- `launch-command.txt`, `emulator-5580-launch.log`, `wait-loop-transcript.log`
- `adb-devices-after-launch.log`, `adb-devices-final.log`
- `crash-qemu-headless-2026-09-24-093335.ips`, `crash-report-summary.txt`
- `env-diagnostics.log`
