# Checkpoint — Lyberry 0.7.0 accepted

2026-09-28. Personal photos can become the main cover after crop/rotate. Original photos retained; separate derived asset; camera/gallery share the preview; cancel and async route ownership guarded. Schema2 unchanged, no new dependencies/providers/credentials.

Astra planned/reviewed/integrated; native Flash implemented, debugged and wrote tests. Root ran Flutter/build/emulator due child cache/socket restrictions. Completed child /root/photo_cover_flash interrupted; no active implementation remains. Existing verified Flash route reused.

Verification: 78 focused Flutter tests, 3 new crop renders, 2 affected editor/version renders, 144 pixel/safety checks; Dart analysis/format clean. **Full suite intentionally skipped at user's request**. Initial failed development logs retained only as history. Fresh three-ABI APK 0.7.0+9 built and installed-r on online emulator-5554. Upgrade preserved existing copy; crop/rotate/save/restart/cancel verified on synthetic fixture; test copy cleaned up. iOS/live camera/native backup dialogs untested.

Source/APK and manifest/checksums in deliverables/lyberry-0.7.0-*. Acceptance details: ACCEPTANCE-PHOTO-COVER.md and evidence/photo-cover/. Baselines/private device snapshots in parent work/ (not delivered). Prior releases retained. No git commit, push or deployment.

---

# Checkpoint — Lyberry 0.6.0 accepted

2026-09-28. Finished status is implemented per physical book/DVD/Blu-ray copy.
Editor checkbox and detail status preserve the personal value through edits and
metadata lookup. New/duplicate copies start false. Other media hide the field
without deleting it. SQLite schema 2 migrates v1 additively; backup exports 2,
reads 1 and 2, validates booleans and retains incoming-wins item updates.

Astra reviewed the source, persistence boundaries and actual renders; Flash
implemented and debugged with the existing native V4.1 Flash route. Root ran
Flutter/Gradle using already-granted cache permissions. No credentials, live
APIs, dependencies, game filters or platform permissions changed.

Verification: 63 focused tests; 513 final full-suite tests; analyzer clean;
151 Dart files formatted with zero changes. Six new/changed renders captured;
95 historical PNGs unchanged. Fresh Gradle build succeeded in 22 seconds.
APK: deliverables/lyberry-0.6.0-debug.apk, version 0.6.0+8, 176257848 bytes,
SHA-256 0d2804a8a6844f6d42eff3c18c48a6929a9c2c664b66f0de9b29337f684d9668.
ZIP and arm64-v8a/armeabi-v7a/x86_64 verified. Source handoff:
deliverables/lyberry-0.6.0-source.zip, manifest and adjacent checksum files.
Older releases retained.

Review records: BRIEF-FINISHED.md, REVIEW-FINISHED.md, ACCEPTANCE-FINISHED.md,
REPORT-FINISHED.md. Evidence: evidence/finished/. Root baselines in parent
work/baselines/finished-pre-060 and finished-review1; root verification/package
scripts in parent work/. No implementation work remains. The completed implementation worker was
interrupted after the final docs-only handoff took an extended time; Astra
finished integrating the report. No worker is active.

Limitations: emulator-5562 remains offline, so install/launch/device library
smoke was unavailable; no user-device data changed. iOS runtime remains untested.
Migration was verified with populated fixtures, not the user's actual library.

---

# Checkpoint — Lyberry 0.5.0 accepted

2026-09-26. UPCMDB movie lookup is complete for Android debug/source handoff.
DVD/Blu-ray barcode lookup, explicit title/year search, edition choices, and own
secure API key Settings are implemented. Original scanned codes reach the editor;
missing movie credentials allow normal general fallback. No schema/dependencies
or working games/platform filter behavior changed.

Astra reviewed the actual patch and security corrections; Flash implemented,
debugged and supplied tests. Root executed Flutter/Gradle commands because cache
permission grants did not propagate to the existing child, and verified the APK.
Same verified native DeepSeek V4.1 Flash route reused; no paid model/API smoke
probe, account changes, ambient keys or repository commit/push/deployment.
Review/acceptance: BRIEF-MOVIES.md, REVIEW-MOVIES.md, ACCEPTANCE-MOVIES.md.
Worker report: REPORT-MOVIES.md. Evidence: evidence/movies/.

Verification: 485 full-suite tests, 80 focused tests, analyzer clean, formatting
147 files zero changes. Current renders passed; historical90 PNGs match baseline.
Fresh Gradle build succeeded after syncing generated Android version properties.
APK: deliverables/lyberry-0.5.0-debug.apk, version0.5.0+7, 176255296 bytes,
SHA25652f986e09d8c760550a1ed723873b3b5e407fa802161dc993daa7d8002bdd01f.
ZIP integrity and arm64-v8a/armeabi-v7a/x86_64 verified. Curated source:
deliverables/lyberry-0.5.0-source.zip, manifest and adjacent checksum files.
Older releases retained. Parent packager: work/package_lyberry_050.py.

Limitations: no authenticated UPCMDB call; sample-EAN coverage unknown. Demo
403 was not treated as no-match. Emulator5562 remained offline, so this version's
install/launch/library-preservation smoke was unavailable; device data unchanged.
iOS runtime remains untested. Enter own UPCMDB key under Settings > Movie lookup
keys to try live movie lookup; no real key is included in the app or archive.

Implementation and final worker report are accepted. The completed child
/root/lyberry_flash was interrupted; no worker remains active. Source is packaged
for handoff and no implementation work remains. Root baselines:
work/baselines/movies-pre-050 and movies-review1.

---

# Checkpoint — Lyberry 0.4.1 accepted

2026-09-25. Games now has a Platform dropdown containing only platforms from
saved games, with sorted case/whitespace deduplication, combined search, reset
on leaving Games and safe refresh after edits/imports/deletes. The user reports
0.4.0 game lookup works well. No schema, metadata provider or credential changes.

Astra contract/review/acceptance: BRIEF-PLATFORM-FILTER.md,
REVIEW-PLATFORM-FILTER.md and ACCEPTANCE-PLATFORM-FILTER.md. Existing native Flash
worker /root/lyberry_flash completed implementation plus one correction cycle;
its completed child was interrupted after delivery. Existing verified route
was reused without a paid smoke probe. Worker report: REPORT-PLATFORM-FILTER.md.

Reviewed actual patch against parent work/baselines/platform-filter-pre-041
(465 source files) and correction against platform-filter-review1. Final 413
suite tests, 16 focused tests, analyzer/format, Android build and emulator
update smoke passed. Widget tests cover populated menus and changing selected
option capitalization. Emulator has no games; its one book copy was preserved.
Astra reviewed renders and verified final APK integrity/hash/all three native
architectures; prior evidence images are unchanged. iOS runtime remains untested.

Final APK: deliverables/lyberry-0.4.1-debug.apk (version 0.4.1+6), 201059210 bytes,
SHA-256 63dc4d555ed4abdad8e604929311e9053a10f272a4b4c19592e6c5f07a4ebe0a.
Source package: deliverables/lyberry-0.4.1-source.zip, with manifest/checksums,
created by parent work/package_lyberry_041.py. Personal databases, caches, keys
and transient golden failures are excluded. Older releases retained.

No required work remains for this request. Shared workspace has accepted changes;
no Git commit/push/deployment. Later requests can reuse the same Flash worker.

# Checkpoint — Lyberry 0.4.0 accepted

2026-09-25. Astra accepted the ScanDex+IGDB games phase after the consolidated
review and a narrow follow-up for queued credential-use races. Flash implemented,
debugged, tested and built; Astra reviewed actual changes against baselines and
accepted evidence. See BRIEF-GAMES.md, REVIEW-GAMES.md, REPORT-GAMES.md,
ACCEPTANCE-GAMES.md and COVERAGE-GAMES.md. Native child /root/lyberry_flash has
finished and was interrupted; no worker remains active.

Current version0.4.0+5: ScanDex barcode identification, IGDB game/platform metadata,
explicit title search with platform choice, own secure ScanDex token and Twitch
client ID/secret Settings, editable/save flow, shared throttling and sanitized
errors. Existing library/schema/backup behavior preserved. No public proxy deployed
or shared credentials bundled; this is personal developer setup.

397tests passed, analyzer/format clean. Final Android APK built and installed over
existing emulator data; library retained at one copy, no fatal/ANR. Astra verified
APK SHA256: 4d10b6e38f918c3acae045b24381b2a7c34fa2a7475b0ca147b8b66e1c236565.
Versioned APK and portable source are in deliverables/; prior releases preserved.
Source packager: parent work/package_lyberry_040.py. Baselines: parent
work/baselines/games-pre-040 and games-review1. Source archive excludes local
DBs, build caches, credentials, signing files and failed-golden scratch output.

No real ScanDex/Twitch/IGDB calls were made and no real keys supplied. Root public
ScanDex UI check for045496367619 returned No results found; synthetic successful
Wii fixtures are not live coverage. User next step: enter credentials in Settings
> Games lookup keys, then scan or use Search games by title. iOS runtime untested.

Unrelated earlier issue remains: Matrix web discovery needs the user's retrieval
log. The0.3.1duplicate-key crash fix remains intact. No paid Tavily/DeepSeek request
or store publishing, Git commit or deployment was performed.

# Checkpoint — Lyberry 0.3.1 accepted

2026-09-25. Fixed the screenshot's Duplicate keys found / web-failure-blocked
error: stateless retrieval rows no longer have duplicate keys. Every error stays
visible. Regression reproduced the original failure and passes after the fix;
22 relevant tests, full313 tests, analyzer and formatting pass. Android0.3.1/code4
built and installed/launched on the emulator without losing the existing test
collection. APK SHA256 independently verified:
533d663545dd6e5d710f89b01b0253112de04d8c2f2ed3014023735baedf3549.

Deliverables: lyberry-0.3.1-debug.apk and lyberry-0.3.1-source.zip under deliverables/.
Prior0.2/0.3 artifacts preserved. See ACCEPTANCE-WEB-ERROR-WIDGET.md and
REPORT-WEB-ERROR-WIDGET.md. Baseline: parent work/baselines/web-failure-widget-pre-031.
Same Flash worker completed and was interrupted; no child remains working.

Pending user issue: why Matrix lookup returns nothing. The crash fix exposes the
retrieval log needed for that diagnosis; it does not change search/provider logic.
No real-key Tavily/DeepSeek request was made. Earlier Matrix success was a web
search here plus direct known-URL production page parsing, not verified Tavily
page discovery. The user has now supplied the duplicate-key crash screenshot.

# Prior checkpoint — Lyberry 0.3.0

2026-09-25. The interrupted web lookup feature is complete for Android debug and
source handoff. See ACCEPTANCE-WEB-LOOKUP.md, REPORT-WEB-LOOKUP.md and README.
No implementation/build blocker remains. Root packages the portable source as
`deliverables/lyberry-0.3.0-source.zip` in the final integration step.

## Current app

Redline/Oxanium Flutter for Android+iOS; local durable library, six media types,
multiple copies, photos/ratings/reviews/notes, scanning/manual code entry, candidate
selection, free replaceable metadata adapters, export/import with atomic
incoming-wins ID merge. Version0.3 adds explicit Tavily web search and Import from
link, structured Product extraction before optional grounded DeepSeek extraction,
secure own-key settings and source-labelled user-reviewed candidates. Existing
library/backup schemas are preserved.

## Accepted evidence

311 tests, analyzer and formatting pass. Android0.3 APK built and installed on
Pixel8a API37. Dummy-key save/replace/restart/remove/restart and missing-key flow
passed; dummy key removed, airplane mode restored, existing test item retained,
no fatal/ANR reported. APK SHA256 independently checked:
e948f4db3d61beb6cfdfacdd1a4f6c20ab8887daa38a98823f8042730b53c47b.

Real key-free production fetches returned Matrix/5051888100639 from iMusic and Wii
Sports Resort/0045496367619 (equivalent to UPC045496367619) from Reway. Root found
and Flash corrected missing TLS in the custom socket. Production pins TCP then
uses SecureSocket.secure with original hostname/platform trust. Acceptance notes
the synthetic TLS-test trust-anchor limitation.

Original0.2 artifacts preserved:
- APK SHA256 7b7fbaf0f4c8e6abb4510eec867f13e8c7836d423aec09e8a95c39e7516fe353.
- Source SHA256 099ced4fa3aa7f838b2cf99a3e15e9bc58906de16b4e0c1d95d5ff5d6aa9ee80.

## Verification limits

No real-key Tavily/DeepSeek request was run; never use ambient Codex/router keys.
User can enter keys in Settings for the complete paid path. iOS needs full Xcode;
real camera decoding, gallery and native file dialogs remain unverified on-device.
No release/store/signing/Git work done.

## Execution and environment

The initial web worker stopped with429 before changing169 baseline source files.
The same worker resumed, completed a consolidated review correction and focused
paid-cancellation/TLS fixes. Root: gpt-6-astra/xhigh, session
01a0ce58-21ba-7102-87e3-f25b74b85048. Worker /root/lyberry_flash, native
astra_flash_builder, deepseek/deepseek-v4.1-flash/high, session
01a0ce70-442b-7683-b784-2fb50e4c8aaa. Prior router HTTP200 records confirmed the
selected provider/route; raw upstream wire slug was not exposed. Completed child
was interrupted per host policy and no child remains working.

No Git repository. Feature baseline: work/baselines/web-lookup-pre-20260924.
Scratch probes/packager are in parent work/. User granted session writes to
~/.gradle, ~/.pub-cache, Flutter bin/cache and flutter_tools/gradle .gradle/build.
Reused Gradle daemons exited silently; fresh --no-daemon --no-watch-fs runs with
Android Studio JBR21 succeeded. EOF did not prove a sandbox cause; no unsandboxed
workaround was used.
