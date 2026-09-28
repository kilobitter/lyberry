# Astra acceptance — 0.3.1 web failure widget hotfix

Accepted 2026-09-25. Compared the actual patch with the374-file pre-hotfix
baseline. Repeated retrieval failures no longer share keys in the same Column:
the unnecessary keys on stateless Text rows are removed. All messages remain,
including repeated kinds and repeated source labels. Candidate action keys also
use occurrence indices; this does not alter selection or retrieval. The confirmed
reported crash was the failure-row keys, not the keys inside separate candidate cards.

Verified saved before/after regression evidence: the original row key causes
FlutterError Duplicate keys found; the corrected code passes with three blocked
page messages (two same host, one different host), retry/manual actions and no
saved library item. Inspected fixture render: all failures are visible with no
error widget. Relevant22 tests and full313-test suite passed; analyzer/format clean.
Root reviewed the source and evidence without rerunning the worker's full suite.

Android0.3.1/code4 built using fresh Gradle/JBR21. Root independently checked
version metadata and APK hash:
533d663545dd6e5d710f89b01b0253112de04d8c2f2ed3014023735baedf3549.
Worker installed with adb -r and verified emulator launch/version, existing one-copy
collection retained, unchanged optional-key statuses and no fatal/ANR.

Original0.2/0.3 artifacts preserved. Root packages the updated0.3.1 source with
tests/docs/native configuration, excluding caches, local SDK paths and device DBs.

This fixes error-log rendering. The user's underlying Matrix lookup failure still
needs diagnosis from the visible retrieval log. Retrieval/provider/key/database
logic was not changed. No live paid-provider test or real-user credential access
was performed. Prior iOS/camera/gallery/file-picker device coverage limits remain.

Same Astra planning/review and native Flash implementation route; child completion
was followed by interrupt_agent. No commits, deployment or release signing.
