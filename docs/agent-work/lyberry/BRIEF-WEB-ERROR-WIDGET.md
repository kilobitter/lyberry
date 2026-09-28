# Web failure widget hotfix — 0.3.1+4

User screenshot shows Flutter Duplicate keys found in Column for
`web-failure-blocked`. Root inspected `_failureBox` in web_lookup_screen.dart:
every row gets a key derived solely from WebFailureKind, so two blocked pages
(or two failures of any same kind) crash the retrieval log. Keys are not used by
existing tests. This is a rendering bug, separate from why a provider/page failed.

Workspace: /Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry
Captured current baseline (374 files):
/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/web-failure-widget-pre-031

## Bounded Flash ownership

Fix lib/ui/screens/web_lookup_screen.dart; regression in test/ui/web_lookup_flow_test.dart
(and minimal necessary test support only). Prefer removing unnecessary row keys
from stateless Text widgets, or use a truly occurrence-unique key. Preserve every
failure row even when kinds and source labels repeat. Do not deduplicate errors or
change retrieval, provider calls, credentials, cancellation, database or library data.

Version pubspec.yaml to0.3.1+4 and Settings version label to0.3.1. Keep the major/minor
User-Agent unchanged. Update README validation/download reference accurately.
Write REPORT-WEB-ERROR-WIDGET.md and evidence/web-error-widget/; build new
deliverables/lyberry-0.3.1-debug.apk and checksum. Preserve0.2/0.3 artifacts.
Root owns this brief, acceptance/checkpoint and source archive.

You are not alone: preserve others' edits. Same native Flash worker, no recursive
delegation/orchestration skill, commits, deploys, real paid API tests or ambient keys.

## Acceptance / execution

1. Regression should first reproduce the original duplicate-key error with
   multiple blocked failures via the real screen/controller flow and synthetic
   clients. Cover repeated kinds with different AND repeated source labels; after
   the fix no Flutter exception, all rows render and retry/manual actions remain.
2. Run the relevant widget test file, analyzer and format. Full-suite rerun is not
   required for this focused UI fix unless new evidence warrants it. A fixture
   screenshot of the repeated-failure state can document the verified layout.
3. Build Android APK0.3.1/code4. Known working command from android uses
   JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home,
   ./gradlew assembleDebug --no-daemon --no-watch-fs with required Flutter args.
   Reused daemons previously failed silently; fresh process succeeds. Session
   cache permissions were granted to ~/.gradle, ~/.pub-cache, Flutter bin/cache
   and flutter_tools/gradle .gradle/build. Do not use unsandboxed UI as a bypass.
4. If existing emulator is available, install -r and verify version/launch preserving
   current collection and settings. No need to repeat credential/network smoke or
   manipulate real user keys. Report exact limits if device unavailable.
5. Final report: actual patch paths, before/after regression results, build/version
   checksum and any device result. Root performs batched acceptance and packaging.
