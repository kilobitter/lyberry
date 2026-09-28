# Web failure widget hotfix - 0.3.1+4

STATUS: **ready_for_review.** The duplicate-key crash in the web lookup
retrieval log is fixed with a reproducing regression, the app version is
0.3.1+4, and `deliverables/lyberry-0.3.1-debug.apk` is built, installed and
verified on the emulator. 0.2.0 and 0.3.0 artifacts are untouched.

Task: `docs/agent-work/lyberry/BRIEF-WEB-ERROR-WIDGET.md`
Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
Baseline: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/web-failure-widget-pre-031` (374 files)

## 1. Cause

`_failureBox` in `lib/ui/screens/web_lookup_screen.dart` gave every log row
`key: Key('web-failure-${failure.kind.name}')`. Two failures of the same kind -
in the user's screenshot two blocked pages - produced two identical keys in the
same `Column`, and Flutter threw `Duplicate keys found.`, replacing the whole
retrieval log with the red error widget. The same class of collision existed for
candidate cards, whose keys were derived from `MetadataCandidate.key`
(`providerId:externalId`), which two products from the same page share.

## 2. Fix

`lib/ui/screens/web_lookup_screen.dart` only:

- the stateless failure rows lost their key entirely (they are not looked up by
  any test or code):

  ```dart
  for (final failure in _controller.failures)
    Text(
      '${failure.stage.label} | ${failure.label}: '
      '${failure.kind.label}. ${failure.message}',
      // No key on purpose: this is a stateless row, and two failures of
      // the same kind - or two failures from the same host - must both
      // render without colliding in the Column.
      style: LyberryType.bodyMuted,
    ),
  ```

- candidate cards take an occurrence index and use it for their keys
  (`web-use-$index`, `web-open-$index`); the redundant `web-source-*` key on the
  stateless source row was removed;
- nothing else changed: no deduplication of errors, no change to retrieval,
  provider calls, credentials, cancellation, database or library data. Every
  repeated failure row still renders, including repeated kinds and repeated
  source labels.

## 3. Reproduction and regression (before/after)

New test in `test/ui/web_lookup_flow_test.dart`:
`repeated failures keep every row without duplicate keys`. It drives the real
screen/controller flow with synthetic clients: Tavily returns three hits, two on
`shop.example` (same host, so the same kind **and** the same label) and one on
`other.example` (same kind, different label), and all three page fetches are
refused with `403`.

| Run | Command | Result |
| --- | --- | --- |
| Before (pre-fix row key temporarily restored, file hash restored afterwards) | `flutter test test/ui/web_lookup_flow_test.dart --plain-name 'repeated failures keep every row without duplicate keys'` | **fails**: `Expected: null / Actual: FlutterError:<Duplicate keys found.>` (`evidence/web-error-widget/regression-before.log`) |
| After | same command | **passes**: `+1: All tests passed!` (`evidence/web-error-widget/regression-after.log`) |

The after-test also asserts that two `shop.example` rows and one `other.example`
row are present, that three `Page blocked` labels render, that the retry
(`Search again`) and manual escape hatches remain, and that nothing was saved to
the library.

## 4. Verification

| Check | Result |
| --- | --- |
| Relevant widget tests (`test/ui/web_lookup_flow_test.dart`, `test/golden/web_lookup_render_test.dart`) | `+22: All tests passed!` (`widget-tests.log`) |
| Full suite (extra safety, not required by the brief) | `+313: All tests passed!` (`full-test-suite.log`) |
| `flutter analyze` | `No issues found!` |
| `dart format --output=none --set-exit-if-changed lib test` | `113 files (0 changed)` |

New fixture render for the repeated-failure state:
`evidence/web-error-widget/web_repeated_failures_390x844.png` (goldens also
updated in `test/golden/goldens/`). It shows the three preserved failure rows
(two identical `shop.example` rows plus `other.example`) and the `Search again`
and `Add it by hand instead` actions - the exact state that used to crash.

## 5. Version

- `pubspec.yaml`: `0.3.1+4`.
- `lib/ui/screens/settings_screen.dart`: Settings shows `Lyberry 0.3.1`.
- `lib/services/user_agent.dart` unchanged (`Lyberry/0.3`), per the brief.
- `android/local.properties` is tool-generated; because this environment builds
  through direct Gradle (the Flutter tool's own Gradle invocation still fails
  silently here), its `flutter.versionName`/`flutter.versionCode` were refreshed
  to `0.3.1`/`4` so the artifact carries the right version. No other generated
  file was edited.

## 6. Build

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
  ./gradlew assembleDebug --no-daemon --no-watch-fs --console=plain \
    -Ptarget-platform=android-arm,android-arm64,android-x64 \
    -Ptarget=lib/main.dart -Pbase-application-name=android.app.Application \
    -Pdart-obfuscation=false -Ptrack-widget-creation=true \
    -Ptree-shake-icons=false
```

- `BUILD SUCCESSFUL in 16s`, 323 tasks. Log:
  `evidence/web-error-widget/build-apk-0.3.1.log`.
- Metadata: `applicationId app.lyberry.lyberry`, `versionName 0.3.1`,
  `versionCode 4`, `minSdk 24`, `targetSdk 36`.
- A second, no-op rebuild produced the **identical** APK hash, so the artifact
  is reproducible and matches the current source (no source file is newer than
  the APK).

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.3.1-debug.apk` |
| Size | 176 126 664 bytes |
| SHA-256 | `533d663545dd6e5d710f89b01b0253112de04d8c2f2ed3014023735baedf3549` (also in `lyberry-0.3.1-debug.apk.sha256`) |

Preserved untouched: `lyberry-0.2.0-debug.apk` (+ checksum, source ZIP) and
`lyberry-0.3.0-debug.apk` (+ checksum, source ZIP and manifest, packaged by
root).

## 7. Device check (`emulator-5554`, Pixel 8a API 37)

| Step | Result |
| --- | --- |
| `adb install -r` 0.3.1 | `Success`; `versionName=0.3.1`, `versionCode=4` |
| Launch | activity focused after `WaitTime 3637`; no crash |
| Existing collection | still exactly one copy (`echo "items=$(sqlite3 ...)"` -> `items=1`); screenshots `device-01-home-031.png`, `device-02-settings-031.png` |
| Settings | shows `App | Lyberry 0.3.1`, both optional keys still `Not configured` (untouched) |
| Log check | `fatal_or_anr_lines=0` |

No credential/network smoke was repeated and no user keys were read, written or
removed: the hotfix is a UI-only change and the brief scoped the device check to
install, version and launch.

## 8. Evidence index (`docs/agent-work/lyberry/evidence/web-error-widget/`)

- `regression-before.log` / `regression-after.log` - the failing and passing
  regression runs
- `widget-tests.log`, `full-test-suite.log`, `analyze.log`, `format-check.log`
- `build-apk-0.3.1.log`, `adb-install-0.3.1.log`,
  `pulled-lyberry-0.3.1.db`
- `web_repeated_failures_390x844.png` (fixture render of the fixed state),
  `render-update*.log`
- `device-01-home-031.png`, `device-02-settings-031.png`, `ui-version.xml`

## 9. Not done / limits

- Live Tavily/DeepSeek calls, credential flows and iOS runtime behaviour were
  not exercised (unchanged from the 0.3.0 report).
- The reproduction uses synthetic clients, which is what the brief asked for; a
  real-world duplicate requires two failures of the same kind, which is exactly
  the shape covered.
- Root owns acceptance, the checkpoint and the 0.3.1 source packaging.
