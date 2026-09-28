#!/usr/bin/env bash
# Exact remaining commands for PHOTO-COVER (Lyberry 0.7.0+9).
#
# This worker's sandbox denies every write under
# /Users/ghijs/development/flutter/bin/cache (the Flutter tool writes
# engine.stamp on every invocation) and denies the adb server socket, so the
# Flutter test suite, the Gradle build and the emulator smoke could not run
# here. See sandbox-blockers.txt for the exact errors. Root has the cache
# access, so these are the commands to run next, in order.
set -euo pipefail

FLUTTER=/Users/ghijs/development/flutter/bin/flutter
DART=/Users/ghijs/development/flutter/bin/cache/dart-sdk/bin/dart
JBR21="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
ANDROID_SDK=/Users/ghijs/Library/Android/sdk
ADB=$ANDROID_SDK/platform-tools/adb
APP=/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry

cd "$APP"

# 1. Focused new tests: crop model, real-pixel transforms, editor flow,
#    SQLite/backup round trip.
$FLUTTER --suppress-analytics --no-version-check test --no-pub \
  test/domain/cover_crop_test.dart \
  test/services/image_transform_test.dart \
  test/ui/photo_cover_flow_test.dart \
  test/data/photo_cover_backup_test.dart

# 2. Create the three new crop-preview goldens, then the one existing golden
#    that shows the Settings version row (now `Lyberry 0.7.0`).
#    Inspect every regenerated PNG before accepting it.
$FLUTTER --suppress-analytics --no-version-check test --no-pub --update-goldens \
  test/golden/photo_cover_render_test.dart
$FLUTTER --suppress-analytics --no-version-check test --no-pub --update-goldens \
  test/golden/movies_render_test.dart

# 3. Analyzer, formatter, then the full suite (the source tree changed, so the
#    full suite must run once after the golden update).
$FLUTTER --suppress-analytics --no-version-check analyze --no-pub
$DART --suppress-analytics format --output=none --set-exit-if-changed lib test
$FLUTTER --suppress-analytics --no-version-check test --no-pub

# 4. Android debug APK. android/local.properties already carries
#    flutter.versionName=0.7.0 / flutter.versionCode=9, so the artifact reports
#    0.7.0 (code 9) without a pub get.
cd "$APP/android"
JAVA_HOME="$JBR21" FLUTTER_SUPPRESS_ANALYTICS=true ./gradlew assembleDebug \
  --no-daemon --no-watch-fs --console=plain \
  -Ptarget-platform=android-arm,android-arm64,android-x64 \
  -Ptarget=lib/main.dart \
  -Pbase-application-name=android.app.Application \
  -Pdart-obfuscation=false \
  -Ptrack-widget-creation=true \
  -Ptree-shake-icons=false

cp "$APP/build/app/outputs/flutter-apk/app-debug.apk" \
  "$APP/deliverables/lyberry-0.7.0-debug.apk"
shasum -a 256 "$APP/deliverables/lyberry-0.7.0-debug.apk" \
  | tee "$APP/deliverables/lyberry-0.7.0-debug.apk.sha256"

# 5. APK identity and the three bundled ABIs.
AAPT=$(ls -1 "$ANDROID_SDK"/build-tools/*/aapt | sort -V | tail -1)
"$AAPT" dump badging "$APP/deliverables/lyberry-0.7.0-debug.apk" \
  | grep -E "^(package|native-code|sdkVersion|targetSdkVersion)"
unzip -l "$APP/deliverables/lyberry-0.7.0-debug.apk" \
  | grep -E "lib/(arm64-v8a|armeabi-v7a|x86_64)/libflutter.so"

# 6. Emulator smoke on emulator-5554 ONLY (emulator-5562 is unrelated).
#    Never uninstall, never clear app data, never reset the emulator.
#    Keep a pre-install copy of the library outside the archive:
#      mkdir -p /Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/private
#      $ADB -s emulator-5554 exec-out run-as app.lyberry.lyberry \
#        cat databases/lyberry.db \
#        > /Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/private/lyberry-pre-070.db
$ADB devices
$ADB -s emulator-5554 install -r "$APP/deliverables/lyberry-0.7.0-debug.apk"
$ADB -s emulator-5554 shell dumpsys package app.lyberry.lyberry \
  | grep -E "versionName|versionCode"
$ADB -s emulator-5554 shell monkey -p app.lyberry.lyberry \
  -c android.intent.category.LAUNCHER 1

# 7. Screenshots for the acceptance loop: create a clearly labelled test copy,
#    select an existing personal photo, crop, rotate, apply, save, check the
#    detail/home cover, relaunch, reopen, then exercise cancellation. Also
#    smoke the already shipped Finished checkbox.
shot() {
  $ADB -s emulator-5554 shell screencap -p "/sdcard/$1"
  $ADB -s emulator-5554 pull "/sdcard/$1" \
    "$APP/docs/agent-work/lyberry/evidence/photo-cover/$1"
}
# shot 01-edit-copy.png    (test copy in Edit copy)
# shot 02-use-as-cover.png (personal photo action)
# shot 03-crop-preview.png (crop rectangle + rotate controls)
# shot 04-rotated.png      (after Rotate right)
# shot 05-applied.png      (derived cover in the editor)
# shot 06-saved-detail.png (derived cover on the detail page)
# shot 07-home-cover.png   (derived cover in the grid)
# shot 08-reopened.png     (after relaunch, cover still derived)
# shot 09-cancelled.png    (cancel path leaves the previous cover)
# shot 10-finished.png     (Finished checkbox still works)

# 8. Runtime error check and cleanup. Remove only the test copy created above.
$ADB -s emulator-5554 logcat -d -t 400 | grep -iE "lyberry|flutter|exception" \
  > "$APP/docs/agent-work/lyberry/evidence/photo-cover/device-logcat.txt"
