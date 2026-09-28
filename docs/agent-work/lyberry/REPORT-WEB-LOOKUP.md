# Web-backed EAN lookup - implementation report (WEB-LOOKUP)

STATUS: **ready_for_review.** All eight findings from `REVIEW-WEB-LOOKUP.md` are
implemented, plus the two residual paid-safety fixes and the production TLS
correction that root's live spot check required. Analyze/format are clean, the
full suite is **311 green tests**, the real public-page probe now returns HTTP
200 with structured products, and the **0.3.0 Android APK is built, installed
and smoke-tested on the emulator** (Section 7).

Task: WEB-LOOKUP (BRIEF-WEB-LOOKUP.md). Version 0.3.0+3.
Workspace: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/outputs/lyberry`
Baseline: `/Users/ghijs/Documents/Codex/2026-09-23/new-chat/work/baselines/web-lookup-pre-20260924`

## 1. What was built

One vertical slice: free APIs stay the default, and a separate, fully explicit
web path handles the codes they miss.

| Layer | File | Behaviour |
| --- | --- | --- |
| Domain | `lib/domain/web_lookup.dart` | `WebCandidate`/`WebCandidateOrigin` (structured vs AI), `WebSourcePage` (evidence with `s1..s3` ids), `WebLookupFailure`/`WebFailureKind` (missing key, invalid key, quota, blocked, no content, malformed, timeout, network, cancelled, unavailable), sanitized `WebLookupException` |
| Key store | `lib/services/keys/api_key_store.dart` | `ApiKeyStore` seam plus `SecureApiKeyStore` (flutter_secure_storage 11.2.0); separate Tavily/DeepSeek entries; nonblank/control-free/bounded validation without vendor-prefix assumptions; a failed write/remove is surfaced, never claimed |
| API transport | `lib/services/api_transport.dart` | Bounded POST: fixed host allowlist, HTTPS only, no redirects, 30 s whole-request deadline, 1 MiB (Tavily) / 128 KiB (DeepSeek) caps, sanitized status mapping (401/403 auth, 402 balance, 429 quota, 5xx service, malformed), no retries, no header/body/key logging |
| Page fetcher | `lib/services/web/page_fetcher.dart`, `address_policy.dart` | Public HTTPS/443 only; userinfo, literal IPv4/IPv6, `localhost`, `.local`/`.internal` and single-label hosts rejected; DNS resolved, every answer checked against a public-address policy (loopback, private, CGNAT, link-local, multicast, documentation, benchmarking, reserved, IPv4-mapped and NAT64/6to4-embedded targets) and the approved address pinned through `HttpClient.connectionFactory` + `Socket.startConnect`; at most 2 redirects, each re-validated; 1 MiB decoded cap; one 10 s deadline covering DNS, headers and body; proxies disabled; sockets aborted on timeout/oversize/cancel; no credentials or cookies to pages |
| Structured data | `lib/services/web/product_extractor.dart` | Bounded JSON-LD scan (60 scripts, 512 KiB/script, depth 12, 4000 nodes); a `Product` only counts when the code is on that same node's own `gtin13/14/12/8/gtin/isbn/isbn13` fields; extracts name/brand/author/publisher/date/description/platform, keeps only cover URLs the existing `CoverDownloader` allowlist already trusts, and recovers bounded visible text (scripts, styles, comments and markup removed) |
| Tavily | `lib/services/web/tavily_client.dart` | `POST /search` with `exact_match:true`, `search_depth:basic`, `auto_parameters:false`, `max_results:3`, `include_answer:false`, `include_raw_content:text`, `include_images:false`; results filtered to public HTTPS pages; `POST /extract` for failed URLs, matched back to the requested URLs so an unrelated answer cannot inject a source |
| DeepSeek | `lib/services/web/deepseek_client.dart` | Grounded JSON extraction (`deepseek-flash`, `thinking:{type:disabled}`, `temperature:0`, `stream:false`, `response_format:json_object`, `max_tokens:2500`); envelope version + barcode must match; `sourceId` must exist; every quote must be a whitespace-normalized substring of that same source and carry the code/title; optional values must also appear in the source text or they become null; wrong types, unknown media, oversized fields, unknown sources and code-inside-longer-digit-run quotes are rejected; the prompt tells the model that page text is untrusted data and to return nothing when the evidence does not establish the product |
| Pipeline | `lib/services/web/web_lookup_service.dart` | Search (or pasted link) -> safe fetch of <=3 unique pages -> structured fast path (returns without any LLM call) -> evidence gate (a page must show the code as a whole identifier) -> at most one DeepSeek call; 90 s budget checked before every stage; single-flight so duplicate taps cannot pay twice; cancellation ignores late results; source ids and URLs are assigned in code, never by the model |
| State | `lib/state/web_lookup_controller.dart` | `idle/running/ready/empty/failed`, mode (search/link), medium hint, no request on construction, explicit `runSearch`/`runLink`, `cancel()` that drops late answers |
| UI | `lib/ui/screens/web_lookup_screen.dart` | Trusted code + kind, medium hint chips (Any + six media types), mode switch, link field with `helperMaxLines`, one primary action, cancel while running, missing-key banner with "Open Settings", results with origin label (`STRUCTURED DATA`/`AI EXTRACTED`), `EXACT CODE MATCH`/`POSSIBLE MATCH`, source domain, `Use this`, `Open source` (url_launcher, only on tap), retrieval log, manual fallback, and the "what gets sent / billed" note |
| Entry points | `lib/ui/screens/candidates_screen.dart`, `lib/ui/navigation.dart` | The empty and all-providers-failed states now expose **Search the web** and **Import from link** next to manual entry; `openWebLookup` returns the same `UseCandidate`/`AddManually` choice the free path uses, so the editor flow is unchanged |
| Settings | `lib/ui/screens/settings_screen.dart` | "Web lookup keys" section: per-provider Saved/Not configured status, concealed input with suggestions/autocorrect/IME learning off, Save/Replace and Remove, setup help and cost/privacy explanation; saving a key never triggers a lookup; `SettingsRouteScreen` lets the web screen send the user there and come back with the code still on screen |
| Composition | `lib/app_services.dart`, `lib/main.dart` | `AppServices` carries `keys` + `webLookup`; `main.dart` wires `SecureApiKeyStore`, `IoApiTransport` (only `api.tavily.com`, `api.deepseek.com`) and `SafePageFetcher`. The automatic `MetadataService` never calls a paid source |

Version bump: `pubspec.yaml` `0.3.0+3`; `lib/services/user_agent.dart` now says
`Lyberry/0.3`; Settings shows "Lyberry 0.3.0". The 0.2.0 artifacts are untouched
in `deliverables/`.

## 2. Platform configuration

- `android/app/src/main/res/xml/backup_rules.xml` - API <= 30 full-backup rules
  excluding the credential shared preferences (the plugin's
  `FlutterSecureStorage` file). The SQLite library keeps the platform's normal
  backup behaviour.
- `android/app/src/main/res/xml/data_extraction_rules.xml` - API 31+ rules
  excluding the same preferences from cloud backup **and** device transfer.
- `android/app/src/main/AndroidManifest.xml` - `android:fullBackupContent` and
  `android:dataExtractionRules` point at those files.
- `ios/Runner/Runner.entitlements` - keychain-access-group entry required by
  flutter_secure_storage; wired into all three Runner build configurations via
  `CODE_SIGN_ENTITLEMENTS` in `ios/Runner.xcodeproj/project.pbxproj`. The Dart
  options request `KeychainAccessibility.first_unlock_this_device` with
  `synchronizable: false`, so keys never sync to iCloud.
- Dependencies: `flutter_secure_storage: ^11.0.0` (resolved 11.2.0) and
  `url_launcher: ^6.3.1` (resolved 6.3.2); `pubspec.lock` updated.

## 3. Consolidated review corrections (REVIEW-WEB-LOOKUP.md)

| # | Finding | What changed | Regression tests |
| --- | --- | --- | --- |
| 1 | Paid-stage cancellation and single-flight | `search`/`importLink` now run through `_singleFlight`, which `await`s the whole pipeline before releasing `_inFlight`; cancellation is an immutable per-operation identity (`_Pipeline` in the service, a run generation in the controller) that no later tap can reset; cancellation/deadline are re-checked after every awaited prerequisite and before every paid stage, including after a slow key read and before Tavily Extract; a cancelled link fetch never reaches extract | `test/services/web/web_lookup_service_test.dart`: lock held during extraction, cancel during extraction, cancelled link fetch performs no extract, cancellation during a slow key read stops before the next stage; `test/ui/web_lookup_flow_test.dart`: a cancelled operation stays cancelled when the user taps again |
| 2 | Whole-pipeline deadline | `_Pipeline.stageTimeout` clamps every stage to the remaining budget; Tavily and DeepSeek each take `min(remaining, 30s)`; Tavily Extract sends the contracted `timeout: 10` field; timeout is a distinct failure kind from user cancellation | service tests: exhausted nonzero budget with a delayed stage yields `timeout` (never `cancelled`) and no later stage runs |
| 3 | Evidence actually sent | Evidence is built once (`DeepSeekClient.buildEvidence`) as a UTF-8 byte-bounded block (12 KiB/source, 36 KiB total); quote and optional-value validation run against the exact per-source text that was transmitted, and a source that did not fit is absent so its candidates are refused; identifier matching tolerates spaces/hyphens in both gating and quote checks (`CodeMatching`); a non-`stop` `finish_reason` is refused | deepseek tests: quotes beyond the transmitted budget are rejected while retained ones pass, UTF-8 byte budget with multilingual text, omitted source cannot be a source, `length`/`content_filter` completions refused; service test: separator-printed code gates and validates |
| 4 | Public IPv6 policy | Only global unicast (`2000::/3`) is accepted, minus explicit special-purpose prefixes (Teredo, benchmarking, AMT, ORCHID v1/v2, `2001:db8::/32`, `3fff::/20`, `5f00::/16`, AS112) and minus 6to4; mapped, NAT64 and deprecated site-local forms are refused outright. DNS timeouts are mapped to the same sanitized timeout failure, and cancellation aborts a stalled page request via a poll timer instead of waiting for the next body chunk | address policy tests (added `fec0::1`, `2001:3::1`, `2001:20::1`, `3fff::1`, `5f00::1`, `2620:4f:8000::1`, mapped/NAT64/6to4 cases); page fetcher tests unchanged and green |
| 5 | Secure storage verification | `SecureApiKeyStore.has` surfaces read failures instead of reporting "Not configured"; `write` compares the read-back to the intended key, so a stale value after a failed replacement is an error; Settings shows `Unavailable` plus the sanitized message and clears it after a successful save/remove | new `test/services/keys/secure_api_key_store_test.dart` drives the real store over a mocked `FlutterSecureStoragePlatform`: save/read/remove, stale write-back, read failure, delete failure, invalid input; messages never contain the key |
| 6 | Narrow result layout | Candidate origin/match badges and the `Use this`/`Open source` actions are `Wrap`s, so they stack instead of overflowing | new renders `web_results_320x568_scale1.6.png`, `web_candidate_320x568_scale1.6.png`, `settings_web_keys_320x568_scale1.6.png`, all inspected with no overflow |
| 7 | Production transport tests | New local-socket coverage of `IoApiTransport` for no-redirect, byte cap, whole-request deadline, sanitized refused-connection/status mapping and no key or body leakage | new `test/services/api_transport_test.dart` (7 tests) |
| 8 | Accurate build diagnosis | Section 7 now states that the silent exit plus daemon EOF is unexplained; the earlier "sandbox kills a Flutter helper" claim is withdrawn, no unsandboxed workaround was used, and root owns the toolchain-cache permission investigation | evidence logs kept, wording corrected |
| 9 | Sticky per-run cancellation (second cycle) | The controller predicate is now `_disposed \|\| generation != _generation \|\| _cancelledGeneration == generation`, so a cancelled run cannot be revived by a later tap, a retry, or `dispose()`; `dispose()` no longer rewrites the cancellation mark | `test/state/web_lookup_controller_test.dart`: cancel → retry (busy) → dispose while the Tavily request is still pending, asserting exactly one API call and no page fetch; plus a fresh run after a cancel is not treated as cancelled |
| 10 | No request without usable evidence | `DeepSeekClient.extract` refuses before any HTTP call when the byte budget leaves no source text (for example oversized title/URL metadata), and quote validation keeps operating on that same sent-source map | deepseek test: oversized metadata produces `noContent` with `transport.calls == 0` |
| 11 | **Production TLS correction (root live spot check)** | The assertion that `connectionFactory` + `Socket.startConnect` would be upgraded by `HttpClient` was wrong: `http_impl.dart:2683` only uses `SecureSocket.startConnect` when no factory is installed, so the fetcher was sending plaintext to port 443 (both sample pages answered HTTP 400). The pinned connection is now upgraded explicitly: `Socket.connect(pinnedAddress, port)` → `SecureSocket.secure(raw, host: uri.host, context: platform default, onBadCertificate: null)` → `ConnectionTask.fromSocket(...)`, with cancel destroying the raw socket, the secured socket and any socket produced late. The 10 s deadline and abort path are unchanged, and DNS is never re-resolved (no `SecureSocket.startConnect` on the original host) | new `test/services/web/page_fetcher_tls_test.dart` (4 tests) against a real local TLS server: TLS-only port, pinned loopback address used, requested host name reaching TLS, strict path refusing an untrusted certificate, plaintext exchange refused. Production installs no certificate hook (`trustsAnyCertificate == false`); see the deviation note in Section 5 |

## 4. Tests (all green)

`flutter analyze` -> `No issues found!`; `dart format --output=none
--set-exit-if-changed lib test` -> `113 files (0 changed)`; full suite
`flutter test` -> **311 tests, all passed** (0.2.0 had 200; this phase adds 111 -
104 in the feature and review cycles, 7 in the final safety/TLS cycle). Logs:
`evidence/web-lookup/analyze.log`, `format-check.log`,
`full-test-suite.log`, `web-lookup-test-files.log`.

**TLS regression deviation (recorded honestly).** The intended evidence was a
test-only trust context holding the local CA. On this Dart build, synthetic trust
anchors are not honoured: a plain `SecureSocket.connect` against a local server
with the test CA in an injected context fails with
`CERTIFICATE_VERIFY_FAILED: application verification failure`, while
`example.com` and `www.google.com` verify normally with the system roots
(`evidence/web-lookup/dart-trust-anchor-probe.log`). The regression therefore
drives the encrypted path with a **test-only** certificate hook plus a test-only
observer for the host name handed to TLS, and asserts separately that production
wiring installs no hook (`SafePageFetcher().trustsAnyCertificate` is false) and
that the strict path refuses the untrusted certificate. The security-relevant
property - production never bypasses verification - is proven; the synthetic
anchor convenience is not available in this environment.

| New test file | Tests | Covers |
| --- | --- | --- |
| `test/services/api_transport_test.dart` | 7 | production POST transport: bearer header, no redirect following, byte cap, whole-request deadline, sanitized refused connection, host allowlist, sanitized status mapping without key/body leakage |
| `test/services/web/address_policy_test.dart` | 6 | scheme/port/userinfo/host rules, private/loopback/link-local/CGNAT/documentation/multicast/reserved IPv4 and IPv6, conservative global-unicast policy (site-local, ORCHID, SRv6, mapped, NAT64, 6to4) |
| `test/services/web/page_fetcher_test.dart` | 11 | real socket fetch, one validated redirect hop, redirect that leaves the policy, hop budget, byte cap, deadline, cancellation, private DNS answer refused, mapped-private answer refused, non-2xx passthrough, no `authorization`/`cookie` headers sent |
| `test/services/web/page_fetcher_tls_test.dart` | 4 | real local TLS: TLS-only port, pinned loopback connection serving the body, requested host name reaching TLS, untrusted certificate refused on the strict path with no production hook, plaintext exchange refused on the same port |
| `test/services/web/product_extractor_test.dart` | 8 | same-node GTIN match, code only elsewhere, `@graph`/arrays, list values, malformed/oversized/deep JSON, cover allowlist, field clipping, visible-text cleanup |
| `test/services/web/tavily_client_test.dart` | 6 | request shape + data minimization, non-public hits dropped, caps, malformed results, sanitized auth/quota/server errors, `extract` mapping with an injected URL ignored |
| `test/services/web/deepseek_client_test.dart` | 14 | documented request, extractive candidate, unknown -> empty, envelope/schema mismatch, unknown source, unverifiable quotes, code inside a longer digit run, wrong types/media/size, page instructions cannot smuggle a candidate, empty/non-JSON answers, no evidence -> no call, evidence cap, transmitted-evidence validation, UTF-8 byte budget, omitted source, non-stop completion |
| `test/services/web/web_lookup_service_test.dart` | 22 | missing key -> no network, structured fast path with no LLM call, UPC -> canonical EAN query while keeping the scanned identity, no code on page -> no LLM call, Tavily raw-content fallback for a blocked page, extract fallback then model, partial retrieval failure, malformed AI answer, cancellation, duplicate taps, import link with no keys, import link needing DeepSeek, private/non-https link refused, conflicting structured format beats the hint, query minimization, bounded evidence, lock held during extraction, cancel during extraction, cancelled link fallback, slow key read cancellation, exhausted budget timeout, separator-printed codes |
| `test/services/keys/api_key_store_test.dart` | 4 | key validation, independent save/delete, failed write/remove surfaced, invalid value never stored |
| `test/services/keys/secure_api_key_store_test.dart` | 6 | real store over a mocked keystore platform: save/read/remove, separate keys, stale write-back, read failure surfaced, delete failure surfaced, invalid input never reaches the platform |
| `test/state/web_lookup_controller_test.dart` | 2 | sticky cancellation: cancel → retry (busy) → dispose while the first request is pending leaves exactly one API call and no page fetch; a fresh run after a cancel is not treated as cancelled |
| `test/ui/web_lookup_flow_test.dart` | 10 | no request on open, missing-key banner + Settings round trip that keeps the code, explicit search shows unsaved reviewed results, medium question when the source does not say, cancel ignores the late answer, a cancelled operation stays cancelled after a new tap, link validation + manual fallback, candidates error state offers the web actions, backup export contains no key values, capture-failure copy never renders the key |
| `test/golden/web_lookup_render_test.dart` | 10 | renders below |

## 5. Renders (visual QA)

Generated by the golden tests and copied to
`docs/agent-work/lyberry/evidence/web-lookup/`:

| File | Shows |
| --- | --- |
| `web_search_idle_390x844.png` | idle search screen: code, medium hints, modes, one explicit action, privacy/billing note |
| `web_results_390x844.png` | structured **Exact code match** result with source domain, `Use this`/`Open source`, retrieval log with a partial failure, manual fallback |
| `web_ai_result_390x844.png` | **AI extracted / Possible match** candidate with provenance |
| `web_missing_key_390x844.png` | missing-key banner, "Open Settings", code retained |
| `web_link_320x568_scale1.6.png` | import-link mode at 320x568 with 1.6x text |
| `web_empty_320x568_scale1.6.png` | no-result state with retry and manual fallback at 320x568/1.6x |
| `settings_web_keys_390x844.png` | key section: Saved/Not configured, concealed inputs, Save/Replace/Remove, storage and cost notes |
| `web_results_320x568_scale1.6.png` | result list at 320x568/1.6x: wrapped origin/match badges, wrapped title, wrapped actions, nothing clipped |
| `web_candidate_320x568_scale1.6.png` | the same candidate card scrolled to its action row, showing `Use this` and `Open source` stacked |
| `settings_web_keys_320x568_scale1.6.png` | key section and privacy copy at 320x568/1.6x |

The previously accepted Redline/Oxanium styling is unchanged; the 0.2.0 settings
goldens were regenerated because this phase adds the key section.

## 6. Sample EANs

Root's `SAMPLE-EAN-CHECK.md` was used as the design input, not as data: the
implementation assumes a UPC may be indexed as its zero-padded EAN-13
(`identifier.canonicalKey` is what gets quoted in the search) while the response
validation and the stored `barcode` keep every equivalent form. The Rarewaves
case (a matching code/title on a page with an unrelated description) is handled
by (a) returning only values that literally appear in the supplied evidence and
(b) treating an AI result as a possible, user-reviewed suggestion. No retailer
prose was copied into fixtures or source.

## 7. Build and device smoke (resolved)

Root resolved the earlier build failure by granting session write access to the
toolchain caches (`~/.gradle`, `~/.pub-cache`, the Flutter bin/cache and the
Flutter Gradle plugin's own `.gradle`/`build`), and the 0.3.0 APK now builds. The
earlier diagnosis history is kept for the record in
`evidence/web-lookup/gradle-help-*.log` and `build-apk-web-lookup.log`; the exact
cause of the previous silent exits is still not claimed beyond "a fresh daemon
with the toolchain caches writable succeeds".

Build command (the one root validated, verbatim, plus the Flutter Gradle
properties so nothing relies on a stale Flutter-generated invocation):

```bash
cd android
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
  ./gradlew assembleDebug --no-daemon --no-watch-fs --console=plain \
    -Ptarget-platform=android-arm,android-arm64,android-x64 \
    -Ptarget=lib/main.dart -Pbase-application-name=android.app.Application \
    -Pdart-obfuscation=false -Ptrack-widget-creation=true \
    -Ptree-shake-icons=false
```

Result: `BUILD SUCCESSFUL in 28s`, 323 tasks (115 executed). An intermediate
attempt failed with `Unable to create debug keystore in /Users/ghijs/.android
because it is not writable`; that write was granted and the rerun succeeded.
Log: `evidence/web-lookup/build-apk-gradle-direct.log`.

| Artifact | Value |
| --- | --- |
| APK | `deliverables/lyberry-0.3.0-debug.apk` |
| Size | 176 126 796 bytes |
| SHA-256 | `e948f4db3d61beb6cfdfacdd1a4f6c20ab8887daa38a98823f8042730b53c47b` (also in `lyberry-0.3.0-debug.apk.sha256`) |
| Metadata | `applicationId app.lyberry.lyberry`, `versionName 0.3.0`, `versionCode 3`, `minSdk 24`, `targetSdk 36` (`build/app/outputs/apk/debug/output-metadata.json`) |

### Device smoke on `emulator-5554` (Pixel 8a API 37)

Installed with `adb install -r` (existing collection preserved: the device
database still holds exactly the one pre-existing test item,
`pulled-lyberry-0.3.0.db`). Screenshots in
`evidence/web-lookup/device-*.png`, semantics dumps alongside them.

| Step | Result |
| --- | --- |
| Install + launch 0.3.0 | `Success`; package `versionName=0.3.0 versionCode=3`; activity focused; Settings shows "Lyberry 0.3.0" |
| Save a synthetic Tavily key | status `Saved` (DeepSeek still `Not configured`) |
| Replace that key | still `Saved`, button label becomes "Replace key" |
| Force-stop + relaunch | status still `Saved` - the value survived a process restart |
| Remove the key | status `Not configured` |
| Force-stop + relaunch again | still `Not configured` - removal persisted, no fake key left on the device |
| No-key flow (airplane mode, restored afterwards) | free providers failed -> candidates screen offers **Search the web** / **Import from link** -> web screen -> explicit tap -> `KEY NEEDED / Add a Tavily key in Settings to use this step. Your code stays on this screen; a new tap is needed after you save a key.` with **Open Settings** |
| Crash check | `fatal_or_anr_lines=0`; app left running with the library intact |

Airplane mode was switched on only for the offline no-key check and switched off
immediately afterwards (`airplane_mode_on=0` re-verified). No real Tavily or
DeepSeek call was made on the device: the key lifecycle performs no lookups, and
the one web action was taken with no key configured and no network.

### Real public-page probe after the TLS fix

`work/live_web_page_probe.dart` (root's key-free probe, one request per URL) run
against the production `SafePageFetcher`, log
`evidence/web-lookup/live-web-page-probe.log`:

| Code | URL | Result |
| --- | --- | --- |
| 5051888100639 | iMusic Matrix Blu-ray | HTTP 200, 377 650 bytes, 471 ms, structured product `Matrix` with `gtin13 5051888100639` |
| 045496367619 | Reway Wii Sports Resort | HTTP 200, 423 792 bytes, 760 ms, structured product `Wii Sports Resort` with `gtin 0045496367619` (UPC matched through its canonical EAN) |

Before the TLS fix root's identical probe received HTTP 400 for both URLs, which
is what exposed the plaintext-to-443 defect now corrected.

## 8. Not done / limitations

- **No live Tavily or DeepSeek call was made.** All paid-path behaviour is
  covered by deterministic fixtures with synthetic keys; no real key was used,
  and no ambient Codex/router credential was read. The only live network traffic
  in this phase was the key-free probe to the two public product pages above.
- The device smoke used a synthetic key that was removed at the end; the
  keystore state was re-verified as `Not configured` after a restart.
- **iOS is untested at runtime** (no Xcode in this environment): entitlement and
  keychain options are configured but not exercised.
- Import-link and search are covered by fixtures; a live third-party page may
  still be blocked, paywalled or differently shaped, which is exactly what the
  retrieval log and the manual fallback are for.
- Cover art is never downloaded from an arbitrary page; only allowlisted hosts
  are kept, so many web candidates will show the medium placeholder.
- The camera, gallery picker, native file dialogs and backup/merge flows are
  unchanged by this phase and keep their previous evidence.

## 9. Changed paths

New: `lib/domain/web_lookup.dart`, `lib/services/api_transport.dart`,
`lib/services/keys/api_key_store.dart`, `lib/services/web/address_policy.dart`,
`lib/services/web/page_fetcher.dart`, `lib/services/web/product_extractor.dart`,
`lib/services/web/tavily_client.dart`, `lib/services/web/deepseek_client.dart`,
`lib/services/web/web_lookup_service.dart`,
`lib/state/web_lookup_controller.dart`,
`lib/ui/screens/web_lookup_screen.dart`,
`lib/services/web/code_matching.dart`,
`test/services/web/*` (6 files), `test/services/api_transport_test.dart`,
`test/services/keys/api_key_store_test.dart`,
`test/services/keys/secure_api_key_store_test.dart`,
`test/services/web/page_fetcher_tls_test.dart`,
`test/state/web_lookup_controller_test.dart`,
`test/support/test_tls_certificates.dart` (test-only synthetic CA and leaf),
`test/ui/web_lookup_flow_test.dart`, `test/golden/web_lookup_render_test.dart`,
`test/support/fake_web.dart`, `android/app/src/main/res/xml/backup_rules.xml`,
`android/app/src/main/res/xml/data_extraction_rules.xml`,
`ios/Runner/Runner.entitlements`.

Modified: `pubspec.yaml`, `pubspec.lock`, `lib/app_services.dart`,
`lib/main.dart`, `lib/services/user_agent.dart`, `lib/ui/navigation.dart`,
`lib/ui/screens/candidates_screen.dart`, `lib/ui/screens/settings_screen.dart`,
`test/support/test_support.dart`, `android/app/src/main/AndroidManifest.xml`,
`ios/Runner.xcodeproj/project.pbxproj`, `README.md`, plus the rebuilt
`deliverables/lyberry-0.3.0-debug.apk` (and `.sha256`), regenerated goldens
(`test/golden/goldens/p2_settings_*.png`) and generated plugin registrants.

Not touched: `docs/agent-work/lyberry/BRIEF-*.md`, `PLAN.md`, `CHECKPOINT.md`,
`ACCEPTANCE-*.md`, `REVIEW-*.md`, `SAMPLE-EAN-CHECK.md`, the 0.2.0 artifacts and
the source ZIP (root-owned).

## 10. Next checkpoint for Astra

1. Review the corrected pinned-TLS connector and the acceptance evidence above
   against `BRIEF-WEB-LOOKUP.md` and `REVIEW-WEB-LOOKUP.md`.
2. Decide whether the 0.3.0 source package should include
   `ios/Runner/Runner.entitlements` (a required build input, not a secret); root
   owns the archive.
3. For acceptance wording: live Tavily/DeepSeek calls and iOS runtime behaviour
   stay explicitly outside verified coverage, and the TLS regression documents
   that synthetic trust anchors are not honoured by this Dart build.
